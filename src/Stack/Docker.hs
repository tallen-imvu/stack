{-# LANGUAGE CPP, DeriveDataTypeable, MultiWayIf, NamedFieldPuns, RankNTypes, RecordWildCards,
             TemplateHaskell, TupleSections #-}

--EKB FIXME: get this all using proper logging infrastructure

-- | Run commands in Docker containers
module Stack.Docker
  (checkVersions
  ,cleanup
  ,CleanupOpts(..)
  ,CleanupAction(..)
  ,dockerCleanupCmdName
  ,dockerCmdName
  ,dockerOptsParser
  ,dockerOptsFromMonoid
  ,dockerPullCmdName
  ,preventInContainer
  ,pull
  ,rerunCmdWithOptionalContainer
  ,rerunCmdWithRequiredContainer
  ,rerunWithOptionalContainer
  ,reset
  ) where

import           Control.Applicative
import           Control.Exception
import           Control.Monad
import           Control.Monad.Writer (execWriter,runWriter,tell)
import           Data.Aeson (FromJSON(..),(.:),(.:?),(.!=),eitherDecode)
import           Data.ByteString.Builder (stringUtf8,charUtf8,toLazyByteString)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import           Data.Char (isSpace,toUpper,isAscii)
import           Data.List (dropWhileEnd,find,intercalate,intersperse,isPrefixOf,isInfixOf,foldl',sortBy)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe
import           Data.Monoid
import           Data.Streaming.Process (ProcessExitedUnsuccessfully(..))
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Data.Time (UTCTime,LocalTime(..),diffDays,utcToLocalTime,getZonedTime,ZonedTime(..))
import           Data.Typeable (Typeable)
import           Options.Applicative.Builder.Extra (maybeBoolFlags)
import           Options.Applicative (Parser,str,option,help,auto,metavar,long,value)
import           Path
import           Path.IO (getWorkingDir,listDirectory)
import           Paths_stack (version)
import           Stack.Constants (projectDockerSandboxDir,stackProgName,stackDotYaml,stackRootEnvVar)
import           Stack.Types
import           Stack.Docker.GlobalDB
import           System.Directory (createDirectoryIfMissing,removeDirectoryRecursive,removeFile)
import           System.Directory (doesDirectoryExist)
import           System.Environment (lookupEnv,getProgName,getArgs,getExecutablePath)
import           System.Exit (ExitCode(ExitSuccess),exitWith)
import           System.FilePath (takeBaseName,isPathSeparator)
import           System.Info (arch,os)
import           System.IO (hPutStrLn,stderr,stdin,stdout,hIsTerminalDevice)
import qualified System.Process as Proc
import           System.Process.PagerEditor (editByteString)
import           System.Process.Read
import           Text.Printf (printf)

#ifndef mingw32_HOST_OS
import           System.Posix.Signals (installHandler,sigTERM,Handler(Catch))
#endif

-- | If Docker is enabled, re-runs the currently running OS command in a Docker container.
-- Otherwise, runs the inner action.
rerunWithOptionalContainer :: Config -> Maybe (Path Abs Dir) -> IO () -> IO ()
rerunWithOptionalContainer config mprojectRoot inner =
     rerunCmdWithOptionalContainer config mprojectRoot getCmdArgs inner
   where
     getCmdArgs =
       do args <- getArgs
          if arch == "x86_64" && os == "linux"
              then do exePath <- getExecutablePath
                      let mountDir = concat ["/tmp/host-",stackProgName]
                          mountPath = concat [mountDir,"/",takeBaseName exePath]
                      return (mountPath
                             ,args
                             ,config{configDocker=docker{dockerMount=Mount exePath mountPath :
                                                                     dockerMount docker}})
              else do progName <- getProgName
                      return (takeBaseName progName,args,config)
     docker = configDocker config

-- | If Docker is enabled, re-runs the OS command returned by the second argument in a
-- Docker container.  Otherwise, runs the inner action.
rerunCmdWithOptionalContainer :: Config
                              -> Maybe (Path Abs Dir)
                              -> IO (FilePath,[String],Config)
                              -> IO ()
                              -> IO ()
rerunCmdWithOptionalContainer config mprojectRoot getCmdArgs inner =
  do inContainer <- getInContainer
     if inContainer || not (dockerEnable (configDocker config))
        then inner
        else do (cmd_,args,config') <- getCmdArgs
                runContainerAndExit config' mprojectRoot cmd_ args [] (return ())

-- | If Docker is enabled, re-runs the OS command returned by the second argument in a
-- Docker container.  Otherwise, runs the inner action.
rerunCmdWithRequiredContainer :: Config -> Maybe (Path Abs Dir) -> IO (FilePath,[String],Config) -> IO ()
rerunCmdWithRequiredContainer config mprojectRoot getCmdArgs =
  do when (not (dockerEnable (configDocker config)))
          (throwIO DockerMustBeEnabledException)
     (cmd_,args,config') <- getCmdArgs
     runContainerAndExit config' mprojectRoot cmd_ args [] (return ())

-- | Error if running in a container.
preventInContainer :: IO () -> IO ()
preventInContainer inner =
  do inContainer <- getInContainer
     if inContainer
        then throwIO OnlyOnHostException
        else inner

-- | 'True' if we are currently running inside a Docker container.
getInContainer :: IO Bool
getInContainer =
  do maybeEnvVar <- lookupEnv sandboxIDEnvVar
     case maybeEnvVar of
       Nothing -> return False
       Just _ -> return True

-- | Run a command in a new Docker container, then exit the process.
runContainerAndExit :: Config
                    -> Maybe (Path Abs Dir)
                    -> FilePath
                    -> [String]
                    -> [(String,String)]
                    -> IO ()
                    -> IO ()
runContainerAndExit config
                    mprojectRoot
                    cmnd
                    args
                    envVars
                    successPostAction =
  do envOverride <- getEnvOverride (configPlatform config)
     checkDockerVersion envOverride
     uidOut <- readProcessStdout envOverride "id" ["-u"]
     gidOut <- readProcessStdout envOverride "id" ["-g"]
     dockerHost <- lookupEnv "DOCKER_HOST"
     dockerCertPath <- lookupEnv "DOCKER_CERT_PATH"
     dockerTlsVerify <- lookupEnv "DOCKER_TLS_VERIFY"
     isStdinTerminal <- hIsTerminalDevice stdin
     isStdoutTerminal <- hIsTerminalDevice stdout
     isStderrTerminal <- hIsTerminalDevice stderr
     pwd <- getWorkingDir
     when (maybe False (isPrefixOf "tcp://") dockerHost &&
           maybe False (isInfixOf "boot2docker") dockerCertPath)
          (hPutStrLn stderr
             ("WARNING: using boot2docker is NOT supported, and not likely to perform well."))
     let image = dockerImage docker
     maybeImageInfo <- inspect envOverride image
     imageInfo <- case maybeImageInfo of
       Just ii -> return ii
       Nothing
         | dockerAutoPull docker ->
             do pullImage envOverride docker image
                mii2 <- inspect envOverride image
                case mii2 of
                  Just ii2 -> return ii2
                  Nothing -> throwIO (InspectFailedException image)
         | otherwise -> throwIO (NotPulledException image)
     let uid = dropWhileEnd isSpace (decodeUtf8 uidOut)
         gid = dropWhileEnd isSpace (decodeUtf8 gidOut)
         imageEnvVars = map (break (== '=')) (icEnv (iiConfig imageInfo))
         (sandboxID,oldImage) =
           case lookupImageEnv sandboxIDEnvVar imageEnvVars of
             Just x -> (x,False)
             Nothing ->
               --EKB TODO: remove this and oldImage after lts-1.x images no longer in use
               let sandboxName = maybe "default" id (lookupImageEnv "SANDBOX_NAME" imageEnvVars)
                   maybeImageCabalRemoteRepoName = lookupImageEnv "CABAL_REMOTE_REPO_NAME" imageEnvVars
                   maybeImageStackageSlug = lookupImageEnv "STACKAGE_SLUG" imageEnvVars
                   maybeImageStackageDate = lookupImageEnv "STACKAGE_DATE" imageEnvVars
               in (case (maybeImageStackageSlug,maybeImageStackageDate) of
                     (Just stackageSlug,_) -> sandboxName ++ "_" ++ stackageSlug
                     (_,Just stackageDate) -> sandboxName ++ "_" ++ stackageDate
                     _ -> sandboxName ++ maybe "" ("_" ++) maybeImageCabalRemoteRepoName
                  ,True)
     sandboxIDDir <- parseRelDir (sandboxID ++ "/")
     let stackRoot = configStackRoot config
         sandboxDir = projectDockerSandboxDir projectRoot
         sandboxSandboxDir = sandboxDir </> $(mkRelDir ".sandbox/") </> sandboxIDDir
         sandboxHomeDir = sandboxDir </> homeDirName
         sandboxRepoDir = sandboxDir </> sandboxIDDir
         sandboxSubdirs = map (\d -> sandboxRepoDir </> d)
                              sandboxedHomeSubdirectories
         isTerm = isStdinTerminal && isStdoutTerminal && isStderrTerminal
         execDockerProcess =
           do mapM_ (createDirectoryIfMissing True)
                    (concat [[toFilePath sandboxHomeDir
                             ,toFilePath sandboxSandboxDir] ++
                             map toFilePath sandboxSubdirs])
              execProcessAndExit
                envOverride
                "docker"
                (concat
                  [["run"
                   ,"--net=host"
                   ,"-e",stackRootEnvVar ++ "=" ++ trimTrailingPathSep stackRoot
                   ,"-e","WORK_UID=" ++ uid
                   ,"-e","WORK_GID=" ++ gid
                   ,"-e","WORK_WD=" ++ trimTrailingPathSep pwd
                   ,"-e","WORK_HOME=" ++ trimTrailingPathSep sandboxRepoDir
                   ,"-e","WORK_ROOT=" ++ trimTrailingPathSep projectRoot
                   ,"-e",hostVersionEnvVar ++ "=" ++ versionString stackVersion
                   ,"-e",requireVersionEnvVar ++ "=" ++ versionString requireContainerVersion
                   ,"-v",trimTrailingPathSep stackRoot ++ ":" ++ trimTrailingPathSep stackRoot
                   ,"-v",trimTrailingPathSep projectRoot ++ ":" ++ trimTrailingPathSep projectRoot
                   ,"-v",trimTrailingPathSep sandboxSandboxDir ++ ":" ++ trimTrailingPathSep sandboxDir
                   ,"-v",trimTrailingPathSep sandboxHomeDir ++ ":" ++ trimTrailingPathSep sandboxRepoDir]
                  ,if oldImage
                     then ["-e",sandboxIDEnvVar ++ "=" ++ sandboxID
                          ,"--entrypoint=/root/entrypoint.sh"]
                     else []
                  ,case (dockerPassHost docker,dockerHost) of
                     (True,Just x@('u':'n':'i':'x':':':'/':'/':s)) -> ["-e","DOCKER_HOST=" ++ x
                                                                      ,"-v",s ++ ":" ++ s]
                     (True,Just x) -> ["-e","DOCKER_HOST=" ++ x]
                     (True,Nothing) -> ["-v","/var/run/docker.sock:/var/run/docker.sock"]
                     (False,_) -> []
                  ,case (dockerPassHost docker,dockerCertPath) of
                     (True,Just x) -> ["-e","DOCKER_CERT_PATH=" ++ x
                                      ,"-v",x ++ ":" ++ x]
                     _ -> []
                  ,case (dockerPassHost docker,dockerTlsVerify) of
                     (True,Just x )-> ["-e","DOCKER_TLS_VERIFY=" ++ x]
                     _ -> []
                  ,concatMap sandboxSubdirArg sandboxSubdirs
                  ,concatMap mountArg (dockerMount docker)
                  ,case dockerContainerName docker of
                     Just name -> ["--name=" ++ name]
                     Nothing -> []
                  ,if dockerDetach docker
                      then ["-d"]
                      else concat [["--rm" | not (dockerPersist docker)]
                                  ,["-t" | isTerm]
                                  ,["-i" | isTerm]]
                  ,dockerRunArgs docker
                  ,[image]
                  ,map (\(k,v) -> k ++ "=" ++ v) envVars
                  ,[cmnd]
                  ,args])
                successPostAction
     updateDockerImageLastUsed config
                               (iiId imageInfo)
                               (toFilePath projectRoot)
     execDockerProcess

  where
    lookupImageEnv name vars =
      case lookup name vars of
        Just ('=':val) -> Just val
        _ -> Nothing
    mountArg (Mount host container) = ["-v",host ++ ":" ++ container]
    sandboxSubdirArg subdir = ["-v",trimTrailingPathSep subdir++ ":" ++ trimTrailingPathSep subdir]
    trimTrailingPathSep = dropWhileEnd isPathSeparator . toFilePath
    projectRoot = fromMaybeProjectRoot mprojectRoot
    docker = configDocker config

-- | Clean-up old docker images and containers.
cleanup :: Config -> CleanupOpts -> IO ()
cleanup config opts =
  do envOverride <- getEnvOverride (configPlatform config)
     checkDockerVersion envOverride
     imagesOut <- readProcessStdout envOverride "docker" ["images","--no-trunc","-f","dangling=false"]
     danglingImagesOut <- readProcessStdout envOverride "docker" ["images","--no-trunc","-f","dangling=true"]
     runningContainersOut <- readProcessStdout envOverride "docker" ["ps","-a","--no-trunc","-f","status=running"]
     restartingContainersOut <- readProcessStdout envOverride "docker" ["ps","-a","--no-trunc","-f","status=restarting"]
     exitedContainersOut <- readProcessStdout envOverride "docker" ["ps","-a","--no-trunc","-f","status=exited"]
     pausedContainersOut <- readProcessStdout envOverride "docker" ["ps","-a","--no-trunc","-f","status=paused"]
     let imageRepos = parseImagesOut imagesOut
         danglingImageHashes = Map.keys (parseImagesOut danglingImagesOut)
         runningContainers = parseContainersOut runningContainersOut ++
                             parseContainersOut restartingContainersOut
         stoppedContainers = parseContainersOut exitedContainersOut ++
                             parseContainersOut pausedContainersOut
     inspectMap <- inspects envOverride
                            (Map.keys imageRepos ++
                             danglingImageHashes ++
                             map fst stoppedContainers ++
                             map fst runningContainers)
     imagesLastUsed <- getDockerImagesLastUsed config
     curTime <- getZonedTime
     let planWriter = buildPlan curTime
                                imagesLastUsed
                                imageRepos
                                danglingImageHashes
                                stoppedContainers
                                runningContainers
                                inspectMap
         plan = toLazyByteString (execWriter planWriter)
     plan' <- case dcAction opts of
                CleanupInteractive -> editByteString (intercalate "-" [stackProgName
                                                                      ,dockerCmdName
                                                                      ,dockerCleanupCmdName
                                                                      ,"plan"])
                                                     plan
                CleanupImmediate -> return plan
                CleanupDryRun -> do LBS.hPut stdout plan
                                    return LBS.empty
     mapM_ (performPlanLine envOverride)
           (reverse (filter filterPlanLine (lines (LBS.unpack plan'))))
     allImageHashesOut <- readProcessStdout envOverride "docker" ["images","-aq","--no-trunc"]
     pruneDockerImagesLastUsed config (lines (decodeUtf8 allImageHashesOut))
  where
    filterPlanLine line =
      case line of
        c:_ | isSpace c -> False
        _ -> True
    performPlanLine envOverride line =
      case filter (not . null) (words (takeWhile (/= '#') line)) of
        [] -> return ()
        (c:_):t:v:_ ->
          do args <- if | toUpper c == 'R' && t == imageStr ->
                            do putStrLn (concat ["Removing image: '",v,"'"])
                               return ["rmi",v]
                        | toUpper c == 'R' && t == containerStr ->
                            do putStrLn (concat ["Removing container: '",v,"'"])
                               return ["rm","-f",v]
                        | otherwise -> throwIO (InvalidCleanupCommandException line)
             e <- try (callProcess envOverride "docker" args)
             case e of
               Left (ProcessExitedUnsuccessfully _ _) ->
                 hPutStrLn stderr (concat ["Could not remove: '",v,"'"])
               Right () -> return ()
        _ -> throwIO (InvalidCleanupCommandException line)
    parseImagesOut = Map.fromListWith (++) . map parseImageRepo . drop 1 . lines . decodeUtf8
      where parseImageRepo :: String -> (String, [String])
            parseImageRepo line =
              case words line of
                repo:tag:hash:_
                  | repo == "<none>" -> (hash,[])
                  | tag == "<none>" -> (hash,[repo])
                  | otherwise -> (hash,[repo ++ ":" ++ tag])
                _ -> throw (InvalidImagesOutputException line)
    parseContainersOut = map parseContainer . drop 1 . lines . decodeUtf8
      where parseContainer line =
              case words line of
                hash:image:rest -> (hash,(image,last rest))
                _ -> throw (InvalidPSOutputException line)
    buildPlan curTime
              imagesLastUsed
              imageRepos
              danglingImageHashes
              stoppedContainers
              runningContainers
              inspectMap =
      do case dcAction opts of
           CleanupInteractive ->
             do buildStrLn
                  (concat
                     ["# STACK DOCKER CLEANUP PLAN"
                     ,"\n#"
                     ,"\n# When you leave the editor, the lines in this plan will be processed."
                     ,"\n#"
                     ,"\n# Lines that begin with 'R' denote an image or container that will be."
                     ,"\n# removed.  You may change the first character to/from 'R' to remove/keep"
                     ,"\n# and image or container that would otherwise be kept/removed."
                     ,"\n#"
                     ,"\n# To cancel the cleanup, delete all lines in this file."
                     ,"\n#"
                     ,"\n# By default, the following images/containers will be removed:"
                     ,"\n#"])
                buildDefault dcRemoveKnownImagesLastUsedDaysAgo "Known images last used"
                buildDefault dcRemoveUnknownImagesCreatedDaysAgo "Unknown images created"
                buildDefault dcRemoveDanglingImagesCreatedDaysAgo "Dangling images created"
                buildDefault dcRemoveStoppedContainersCreatedDaysAgo "Stopped containers created"
                buildDefault dcRemoveRunningContainersCreatedDaysAgo "Running containers created"
                buildStrLn
                  (concat
                     ["#"
                     ,"\n# The default plan can be adjusted using command-line arguments."
                     ,"\n# Run '" ++ unwords [stackProgName, dockerCmdName, dockerCleanupCmdName] ++
                      " --help' for details."
                     ,"\n#"])
           _ -> buildStrLn
                  (unlines
                    ["# Lines that begin with 'R' denote an image or container that will be."
                    ,"# removed."])
         buildSection "KNOWN IMAGES (pulled/used by stack)"
                      imagesLastUsed
                      buildKnownImage
         buildSection "UNKNOWN IMAGES (not managed by stack)"
                      (sortCreated (Map.toList (foldl' (\m (h,_) -> Map.delete h m)
                                                       imageRepos
                                                       imagesLastUsed)))
                      buildUnknownImage
         buildSection "DANGLING IMAGES (no named references and not depended on by other images)"
                      (sortCreated (map (,()) danglingImageHashes))
                      buildDanglingImage
         buildSection "STOPPED CONTAINERS"
                      (sortCreated stoppedContainers)
                      (buildContainer (dcRemoveStoppedContainersCreatedDaysAgo opts))
         buildSection "RUNNING CONTAINERS"
                      (sortCreated runningContainers)
                      (buildContainer (dcRemoveRunningContainersCreatedDaysAgo opts))
      where
        buildDefault accessor description =
          case accessor opts of
            Just days -> buildStrLn ("#   - " ++ description ++ " at least " ++ showDays days ++ ".")
            Nothing -> return ()
        sortCreated l =
          reverse (sortBy (\(_,_,a) (_,_,b) -> compare a b)
                          (catMaybes (map (\(h,r) -> fmap (\ii -> (h,r,iiCreated ii))
                                                          (Map.lookup h inspectMap))
                                          l)))
        buildSection sectionHead items itemBuilder =
          do let (anyWrote,b) = runWriter (forM items itemBuilder)
             if or anyWrote
               then do buildSectionHead sectionHead
                       tell b
               else return ()
        buildKnownImage (imageHash,lastUsedProjects) =
          case Map.lookup imageHash imageRepos of
            Just repos@(_:_) ->
              do case lastUsedProjects of
                   (l,_):_ -> forM_ repos (buildImageTime (dcRemoveKnownImagesLastUsedDaysAgo opts) l)
                   _ -> forM_ repos buildKeepImage
                 forM_ lastUsedProjects buildProject
                 buildInspect imageHash
                 return True
            _ -> return False
        buildUnknownImage (hash, repos, created) =
          case repos of
            [] -> return False
            _ -> do forM_ repos (buildImageTime (dcRemoveUnknownImagesCreatedDaysAgo opts) created)
                    buildInspect hash
                    return True
        buildDanglingImage (hash, (), created) =
          do buildImageTime (dcRemoveDanglingImagesCreatedDaysAgo opts) created hash
             buildInspect hash
             return True
        buildContainer removeAge (hash,(image,name),created) =
          do let display = (name ++ " (image: " ++ image ++ ")")
             buildTime containerStr removeAge created display
             buildInspect hash
             return True
        buildProject (lastUsedTime, projectPath) =
          buildInfo ("Last used " ++
                     showDaysAgo lastUsedTime ++
                     " in " ++
                     projectPath)
        buildInspect hash =
          case Map.lookup hash inspectMap of
            Just (Inspect{iiCreated,iiVirtualSize}) ->
              buildInfo ("Created " ++
                         showDaysAgo iiCreated ++
                         maybe ""
                               (\s -> " (size: " ++
                                      printf "%g" (fromIntegral s / 1024.0 / 1024.0 :: Float) ++
                                      "M)")
                               iiVirtualSize)
            Nothing -> return ()
        showDays days =
          case days of
            0 -> "today"
            1 -> "yesterday"
            n -> show n ++ " days ago"
        showDaysAgo oldTime = showDays (daysAgo oldTime)
        daysAgo oldTime =
          let ZonedTime (LocalTime today _) zone = curTime
              LocalTime oldDay _ = utcToLocalTime zone oldTime
          in diffDays today oldDay
        buildImageTime = buildTime imageStr
        buildTime t removeAge time display =
          case removeAge of
            Just d | daysAgo time >= d -> buildStrLn ("R " ++ t ++ " " ++ display)
            _ -> buildKeep t display
        buildKeep t d = buildStrLn ("  " ++ t ++ " " ++ d)
        buildKeepImage = buildKeep imageStr
        buildSectionHead s = buildStrLn ("\n#\n# " ++ s ++ "\n#\n")
        buildInfo = buildStrLn . ("        # " ++)
        buildStrLn l = do buildStr l
                          tell (charUtf8 '\n')
        buildStr = tell . stringUtf8

    imageStr = "image"
    containerStr = "container"

-- | Inspect Docker image or container.
inspect :: EnvOverride -> String -> IO (Maybe Inspect)
inspect envOverride image =
  do results <- inspects envOverride [image]
     case Map.toList results of
       [] -> return Nothing
       [(_,i)] -> return (Just i)
       _ -> throwIO (InvalidInspectOutputException "expect a single result")

-- | Inspect multiple Docker images and/or containers.
inspects :: EnvOverride -> [String] -> IO (Map String Inspect)
inspects _ [] = return Map.empty
inspects envOverride images =
  do maybeInspectOut <- tryProcessStdout envOverride "docker" ("inspect" : images)
     case maybeInspectOut of
       Right inspectOut ->
         -- filtering with 'isAscii' to workaround @docker inspect@ output containing invalid UTF-8
         case eitherDecode (LBS.pack (filter isAscii (decodeUtf8 inspectOut))) of
           Left msg -> throwIO (InvalidInspectOutputException msg)
           Right results -> return (Map.fromList (map (\r -> (iiId r,r)) results))
       Left (ProcessExitedUnsuccessfully _ _) -> return Map.empty

-- | Pull latest version of configured Docker image from registry.
pull :: Config -> IO ()
pull config =
  do envOverride <- getEnvOverride (configPlatform config)
     checkDockerVersion envOverride
     pullImage envOverride docker (dockerImage docker)
  where docker = configDocker config

-- | Pull Docker image from registry.
pullImage :: EnvOverride -> DockerOpts -> String -> IO ()
pullImage envOverride docker image =
  do putStrLn ("Pulling from registry: " ++ image)
     when (dockerRegistryLogin docker)
          (do putStrLn "You may need to log in."
              callProcess
                envOverride
                "docker"
                (concat
                   [["login"]
                   ,maybe [] (\u -> ["--username=" ++ u]) (dockerRegistryUsername docker)
                   ,maybe [] (\p -> ["--password=" ++ p]) (dockerRegistryPassword docker)
                   ,[takeWhile (/= '/') image]]))
     e <- try (callProcess envOverride "docker" ["pull",image])
     case e of
       Left (ProcessExitedUnsuccessfully _ _) -> throwIO (PullFailedException image)
       Right () -> return ()

-- | Check docker version (throws exception if incorrect)
checkDockerVersion :: EnvOverride -> IO ()
checkDockerVersion envOverride =
  do dockerExists <- doesExecutableExist envOverride "docker"
     when (not dockerExists)
          (throwIO DockerNotInstalledException)
     dockerVersionOut <- readProcessStdout envOverride "docker" ["--version"]
     case words (decodeUtf8 dockerVersionOut) of
       (_:_:v:_) ->
         case parseVersionFromString (dropWhileEnd (== ',') v) of
           Just v'
             | v' < minimumDockerVersion ->
               throwIO (DockerTooOldException minimumDockerVersion v')
             | v' `elem` prohibitedDockerVersions ->
               throwIO (DockerVersionProhibitedException prohibitedDockerVersions v')
             | otherwise ->
               return ()
           _ -> throwIO InvalidVersionOutputException
       _ -> throwIO InvalidVersionOutputException
  where minimumDockerVersion = $(mkVersion "1.3.0")
        prohibitedDockerVersions = [$(mkVersion "1.2.0")]

-- | Run a process, then exit with the same exit code.
execProcessAndExit :: EnvOverride -> FilePath -> [String] -> IO () -> IO ()
execProcessAndExit envOverride cmnd args successPostAction =
  do (_, _, _, h) <- Proc.createProcess (Proc.proc cmnd args){Proc.delegate_ctlc = True
                                                             ,Proc.env = envHelper envOverride}
#ifndef mingw32_HOST_OS
     _ <- installHandler sigTERM (Catch (Proc.terminateProcess h)) Nothing
#endif
     exitCode <- Proc.waitForProcess h
     when (exitCode == ExitSuccess)
          successPostAction
     exitWith exitCode

-- | Remove the project's Docker sandbox.
reset :: Maybe (Path Abs Dir) -> Bool -> IO ()
reset maybeProjectRoot keepHome =
  removeDirectoryContents
    (projectDockerSandboxDir projectRoot)
    [homeDirName | keepHome]
    []
  where projectRoot = fromMaybeProjectRoot maybeProjectRoot

-- | Remove the contents of a directory, without removing the directory itself.
-- This is used instead of 'FS.removeTree' to clear bind-mounted directories, since
-- removing the root of the bind-mount won't work.
removeDirectoryContents :: Path Abs Dir -- ^ Directory to remove contents of
                        -> [Path Rel Dir] -- ^ Top-level directory names to exclude from removal
                        -> [Path Rel File] -- ^ Top-level file names to exclude from removal
                        -> IO ()
removeDirectoryContents path excludeDirs excludeFiles =
  do isRootDir <- doesDirectoryExist (toFilePath path)
     when isRootDir
          (do (lsd,lsf) <- listDirectory path
              forM_ lsd
                    (\d -> unless (dirname d `elem` excludeDirs)
                                  (removeDirectoryRecursive (toFilePath d)))
              forM_ lsf
                    (\f -> unless (filename f `elem` excludeFiles)
                                  (removeFile (toFilePath f))))

-- | Subdirectories of the home directory to sandbox between GHC/Stackage versions.
sandboxedHomeSubdirectories :: [Path Rel Dir]
sandboxedHomeSubdirectories =
  [$(mkRelDir ".ghc/")
  ,$(mkRelDir ".cabal/")
  ,$(mkRelDir ".ghcjs/")]

-- | Name of home directory within @.docker-sandbox@.
homeDirName :: Path Rel Dir
homeDirName = $(mkRelDir ".home/")

-- | Check host 'stack' version
checkHostStackVersion :: Version -> IO ()
checkHostStackVersion minVersion =
  do maybeHostVer <- lookupEnv hostVersionEnvVar
     case parseVersionFromString =<< maybeHostVer of
       Just hostVer
         | hostVer < minVersion -> throwIO (HostStackTooOldException minVersion (Just hostVer))
         | otherwise -> return ()
       Nothing ->
          do inContainer <- getInContainer
             if inContainer
                then throwIO (HostStackTooOldException minVersion Nothing)
                else return ()


-- | Check host and container 'stack' versions are compatible.
checkVersions :: IO ()
checkVersions =
  do inContainer <- getInContainer
     when inContainer
       (do checkHostStackVersion requireHostVersion
           maybeReqVer <- lookupEnv requireVersionEnvVar
           case parseVersionFromString =<< maybeReqVer of
             Just reqVer
               | stackVersion < reqVer -> throwIO (ContainerStackTooOldException reqVer stackVersion)
               | otherwise -> return ()
             _ -> return ())

-- | Options parser configuration for Docker.
dockerOptsParser :: Parser DockerOptsMonoid
dockerOptsParser =
    DockerOptsMonoid
    <$> maybeBoolFlags dockerCmdName
                       "using a Docker container"
    <*> ((Just . DockerMonoidRepo) <$> option str (long (dockerOptName dockerRepoArgName) <>
                                                   metavar "NAME" <>
                                                   help "Docker repository name") <|>
         (Just . DockerMonoidImage) <$> option str (long (dockerOptName dockerImageArgName) <>
                                                    metavar "IMAGE" <>
                                                    help "Exact Docker image ID (overrides docker-repo)") <|>
         pure Nothing)
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> maybeBoolFlags (dockerOptName dockerAutoPullArgName)
                       "automatic pulling latest version of image"
    <*> maybeBoolFlags (dockerOptName dockerDetachArgName)
                        "running a detached Docker container"
    <*> maybeBoolFlags (dockerOptName dockerPersistArgName)
                       "not deleting container after it exits"
    <*> maybeStrOption (long (dockerOptName dockerContainerNameArgName) <>
                        metavar "NAME" <>
                        help "Docker container name")
    <*> wordsStrOption (long (dockerOptName dockerRunArgsArgName) <>
                        value [] <>
                        metavar "'ARG1 [ARG2 ...]'" <>
                        help ("Additional arguments to pass to 'docker run'"))
    <*> many (option auto (long (dockerOptName dockerMountArgName) <>
                           metavar "(PATH | HOST-PATH:CONTAINER-PATH)" <>
                           help ("Mount volumes from host in container " ++
                                 "(may specify mutliple times)")))
    <*> maybeBoolFlags (dockerOptName dockerPassHostArgName)
                       "passing Docker daemon connection information into container"
  where
    dockerOptName optName = dockerCmdName ++ "-" ++ T.unpack optName
    maybeStrOption = optional . option str
    wordsStrOption = option (fmap words str)

-- | Interprets DockerOptsMonoid options.
dockerOptsFromMonoid :: Maybe Project -> DockerOptsMonoid -> DockerOpts
dockerOptsFromMonoid mproject DockerOptsMonoid{..} = DockerOpts
  {dockerEnable = fromMaybe False dockerMonoidEnable
  ,dockerImage =
     let defaultTag =
           case mproject of
             Nothing -> ""
             Just proj ->
               case projectResolver proj of
                 ResolverSnapshot n@(LTS _ _) -> ":" ++  (T.unpack (renderSnapName n))
                 _ -> throw (ResolverNotSupportedException (projectResolver proj))
     in case dockerMonoidRepoOrImage of
       Nothing -> "fpco/dev" ++ defaultTag
       Just (DockerMonoidImage image) -> image
       Just (DockerMonoidRepo repo) ->
         case find (`elem` ":@") repo of
           Just _ -> -- Repo already specified a tag or digest, so don't append default
                     repo
           Nothing -> repo ++ defaultTag
  ,dockerRegistryLogin = fromMaybe (isJust (emptyToNothing dockerMonoidRegistryUsername))
                                   dockerMonoidRegistryLogin
  ,dockerRegistryUsername = emptyToNothing dockerMonoidRegistryUsername
  ,dockerRegistryPassword = emptyToNothing dockerMonoidRegistryPassword
  ,dockerAutoPull = fromMaybe False dockerMonoidAutoPull
  ,dockerDetach = fromMaybe False dockerMonoidDetach
  ,dockerPersist = fromMaybe False dockerMonoidPersist
  ,dockerContainerName = emptyToNothing dockerMonoidContainerName
  ,dockerRunArgs = dockerMonoidRunArgs
  ,dockerMount = dockerMonoidMount
  ,dockerPassHost = fromMaybe False dockerMonoidPassHost
  }
  where emptyToNothing Nothing = Nothing
        emptyToNothing (Just s) | null s = Nothing
                                | otherwise = Just s

-- | Decode ByteString to UTF8.
decodeUtf8 :: BS.ByteString -> String
decodeUtf8 bs = T.unpack (T.decodeUtf8 (bs))


-- | Fail with friendly error if project root not set.
fromMaybeProjectRoot :: Maybe (Path Abs Dir) -> Path Abs Dir
fromMaybeProjectRoot = fromMaybe (throw CannotDetermineProjectRootException)

-- | Environment variable to the host's stack version.
hostVersionEnvVar :: String
hostVersionEnvVar = "STACK_DOCKER_HOST_VERSION"

-- | Environment variable to pass required container stack version.
requireVersionEnvVar :: String
requireVersionEnvVar = "STACK_DOCKER_REQUIRE_VERSION"

-- | Environment variable that contains the sandbox ID.
sandboxIDEnvVar :: String
sandboxIDEnvVar = "DOCKER_SANDBOX_ID"

-- | Command-line argument for "docker"
dockerCmdName :: String
dockerCmdName = "docker"

-- | Command-line argument for @docker pull@.
dockerPullCmdName :: String
dockerPullCmdName = "pull"

-- | Command-line argument for @docker cleanup@.
dockerCleanupCmdName :: String
dockerCleanupCmdName = "cleanup"

-- | Version of 'stack' required to be installed in container.
requireContainerVersion :: Version
requireContainerVersion = $(mkVersion "0.0.0")

-- | Version of 'stack' required to be installed on the host.
requireHostVersion :: Version
requireHostVersion = $(mkVersion "0.0.0")

-- | Stack cabal package version
stackVersion :: Version
stackVersion = fromCabalVersion version

-- | Options for 'cleanup'.
data CleanupOpts = CleanupOpts
  { dcAction                                :: !CleanupAction
  , dcRemoveKnownImagesLastUsedDaysAgo      :: !(Maybe Integer)
  , dcRemoveUnknownImagesCreatedDaysAgo     :: !(Maybe Integer)
  , dcRemoveDanglingImagesCreatedDaysAgo    :: !(Maybe Integer)
  , dcRemoveStoppedContainersCreatedDaysAgo :: !(Maybe Integer)
  , dcRemoveRunningContainersCreatedDaysAgo :: !(Maybe Integer) }
  deriving (Show)

-- | Cleanup action.
data CleanupAction = CleanupInteractive
                   | CleanupImmediate
                   | CleanupDryRun
  deriving (Show)

-- | Parsed result of @docker inspect@.
data Inspect = Inspect
  {iiConfig      :: ImageConfig
  ,iiCreated     :: UTCTime
  ,iiId          :: String
  ,iiVirtualSize :: Maybe Integer }
  deriving (Show)

-- | Parse @docker inspect@ output.
instance FromJSON Inspect where
  parseJSON v =
    do o <- parseJSON v
       (Inspect <$> o .: T.pack "Config"
                <*> o .: T.pack "Created"
                <*> o .: T.pack "Id"
                <*> o .:? T.pack "VirtualSize")

-- | Parsed @Config@ section of @docker inspect@ output.
data ImageConfig = ImageConfig
  {icEnv :: [String]}
  deriving (Show)

-- | Parse @Config@ section of @docker inspect@ output.
instance FromJSON ImageConfig where
  parseJSON v =
    do o <- parseJSON v
       (ImageConfig <$> o .:? T.pack "Env" .!= [])

-- | Exceptions thrown by Stack.Docker.
data StackDockerException
  = DockerMustBeEnabledException
    -- ^ Docker must be enabled to use the command.
  | OnlyOnHostException
    -- ^ Command must be run on host OS (not in a container).
  | InspectFailedException String
    -- ^ @docker inspect@ failed.
  | NotPulledException String
    -- ^ Image does not exist.
  | InvalidCleanupCommandException String
    -- ^ Input to @docker cleanup@ has invalid command.
  | InvalidImagesOutputException String
    -- ^ Invalid output from @docker images@.
  | InvalidPSOutputException String
    -- ^ Invalid output from @docker ps@.
  | InvalidInspectOutputException String
    -- ^ Invalid output from @docker inspect@.
  | PullFailedException String
    -- ^ Could not pull a Docker image.
  | DockerTooOldException Version Version
    -- ^ Installed version of @docker@ below minimum version.
  | DockerVersionProhibitedException [Version] Version
    -- ^ Installed version of @docker@ is prohibited.
  | InvalidVersionOutputException
    -- ^ Invalid output from @docker --version@.
  | HostStackTooOldException Version (Maybe Version)
    -- ^ Version of @stack@ on host is too old for version in image.
  | ContainerStackTooOldException Version Version
    -- ^ Version of @stack@ in container/image is too old for version on host.
  | ResolverNotSupportedException Resolver
    -- ^ Only LTS resolvers are supported for default image tag.
  | CannotDetermineProjectRootException
    -- ^ Can't determine the project root (where to put @.docker-sandbox@).
  | DockerNotInstalledException
    -- ^ @docker --version@ failed.
  deriving (Typeable)

-- | Exception instance for StackDockerException.
instance Exception StackDockerException

-- | Show instance for StackDockerException.
instance Show StackDockerException where
  show DockerMustBeEnabledException =
    concat ["Docker must be enabled in your ",toFilePath stackDotYaml," to use this command."]
  show OnlyOnHostException =
    "This command must be run on host OS (not in a Docker container)."
  show (InspectFailedException image) =
    concat ["'docker inspect' failed for image after pull: ",image,"."]
  show (NotPulledException image) =
    concat ["The Docker image referenced by "
           ,toFilePath stackDotYaml
           ," has not\nbeen downloaded:\n    "
           ,image
           ,"\n\nRun '"
           ,unwords [stackProgName, dockerCmdName, dockerPullCmdName]
           ,"' to download it, then try again."]
  show (InvalidCleanupCommandException line) =
    concat ["Invalid line in cleanup commands: '",line,"'."]
  show (InvalidImagesOutputException line) =
    concat ["Invalid 'docker images' output line: '",line,"'."]
  show (InvalidPSOutputException line) =
    concat ["Invalid 'docker ps' output line: '",line,"'."]
  show (InvalidInspectOutputException msg) =
    concat ["Invalid 'docker inspect' output: ",msg,"."]
  show (PullFailedException image) = 
    concat ["Could not pull Docker image:\n    "
           ,image
           ,"\nThere may not be an image on the registry for your resolver's LTS version in\n"
           ,toFilePath stackDotYaml
           ,"."]
  show (DockerTooOldException minVersion haveVersion) =
    concat ["Minimum docker version '"
           ,versionString minVersion
           ,"' is required (you have '"
           ,versionString haveVersion
           ,"')."]
  show (DockerVersionProhibitedException prohibitedVersions haveVersion) =
    concat ["These Docker versions are prohibited (you have '"
           ,versionString haveVersion
           ,"'): "
           ,concat (intersperse ", " (map versionString prohibitedVersions))
           ,"."]
  show InvalidVersionOutputException =
    "Cannot get Docker version (invalid 'docker --version' output)."
  show (HostStackTooOldException minVersion (Just hostVersion)) =
    concat ["The host's version of '"
           ,stackProgName
           ,"' is too old for this Docker image.\nVersion "
           ,versionString minVersion
           ," is required; you have "
           ,versionString hostVersion
           ,"."]
  show (HostStackTooOldException minVersion Nothing) =
    concat ["The host's version of '"
           ,stackProgName
           ,"' is too old.\nVersion "
           ,versionString minVersion
           ," is required."]
  show (ContainerStackTooOldException requiredVersion containerVersion) =
    concat ["The Docker container's version of '"
           ,stackProgName
           ,"' is too old.\nVersion "
           ,versionString requiredVersion
           ," is required; the container has "
           ,versionString containerVersion
           ,"."]
  show (ResolverNotSupportedException resolver) =
    concat ["Resolver not supported for Docker images:\n    "
           ,show resolver
           ,"\nUse an LTS resolver, or set the '"
           ,T.unpack dockerImageArgName
           ,"' explicitly, in "
           ,toFilePath stackDotYaml
           ,"."]
  show CannotDetermineProjectRootException =
    "Cannot determine project root directory for Docker sandbox."
  show DockerNotInstalledException=
    "Cannot find 'docker' in PATH.  Is Docker installed?"
