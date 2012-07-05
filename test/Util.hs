module Util where

import Prelude hiding (FilePath)

import Control.Concurrent.Chan
import Control.Exception
import Filesystem.Path.CurrentOS
import System.Directory
import System.Environment
import System.Exit
import System.IO.FSNotify
import System.IO.FSNotify.Types

data ChanActionEnv =
    ChanEnv
  | ActionEnv
data DirTreeEnv =
    DirEnv
  | TreeEnv
data TestContext = TestContext ChanActionEnv DirTreeEnv ActionPredicate

data TestReport = TestReport FilePath [Event] deriving (Show)
data TestResult = TestResult Bool String TestReport deriving (Show)
type TestAction = FilePath -> IO ()
type EventProcessor = TestReport -> IO TestResult

testName :: IO String
testName = do
    n <- getProgName
    return (n ++ "-sandbox")

withTempDir :: (String -> IO ()) -> IO ()
withTempDir fn = do
    path <- testName
    bracket
      (do
       putStrLn $ "Creating " ++ path
       createDirectory path
       putStrLn $ path ++ " created"
       return path)
      (\dir -> do
       putStrLn $ "Removing " ++ path
       removeDirectoryRecursive dir
       putStrLn $ path ++ " removed")
      (fn)

performAction :: TestAction -> FilePath -> IO ()
performAction action path = do
  putStrLn "Performing test action"
  _      <- action path
  putStrLn "Test action complete"

reportOnAction :: FilePath -> EventChannel -> EventProcessor -> IO TestResult
reportOnAction = reportOnAction' []

reportOnAction' :: [Event] -> FilePath -> EventChannel -> EventProcessor -> IO TestResult
reportOnAction' events path chan processor = do
  putStrLn $ "Processing events: " ++ show events
  result@(TestResult status _ _) <- processor (TestReport path events)
  putStrLn "Events processed"
  if not status then do
    putStrLn "Getting event from chan"
    event <- readChan chan
    putStrLn $ "event retrieved: " ++ show event
    reportOnAction' (event:events) path chan processor
    else
    return result

actAndReport :: TestAction -> FilePath -> EventChannel -> EventProcessor -> IO TestResult
actAndReport action path chan processor = do
  performAction action path
  reportOnAction path chan processor

inEnv :: ChanActionEnv -> DirTreeEnv -> ActionPredicate -> TestAction -> EventProcessor -> IO ()
inEnv caEnv dtEnv reportPred action eventProcessor = withTempDir $ \pathString ->
  withManager $ \manager -> do
    chan <- newChan
    let path = decodeString pathString
    putStrLn $ "Creating watch: " ++ pathString
    _ <- watchInEnv caEnv dtEnv manager path reportPred chan
    putStrLn $ "Watch created: " ++ pathString
    actAndReport action path chan eventProcessor >>= exitStatus

actionAsChan :: (WatchManager -> FilePath -> ActionPredicate -> Action       -> IO ()) ->
                 WatchManager -> FilePath -> ActionPredicate -> EventChannel -> IO ()
actionAsChan actionFunction wm fp ap ec = actionFunction wm fp ap (writeChan ec)

watchInEnv ChanEnv   DirEnv  = watchDirChan
watchInEnv ChanEnv   TreeEnv = watchTreeChan
watchInEnv ActionEnv DirEnv  = actionAsChan watchDirAction
watchInEnv ActionEnv TreeEnv = actionAsChan watchTreeAction

exitStatus :: TestResult -> IO ()
exitStatus (TestResult True  _ _)  = do
  putStrLn "Should exit success"
  testSuccess
exitStatus (TestResult False explanation report) = do
  putStrLn "Should exit failure"
  explainFailure explanation report >> testFailure
exitStatus _ = do
  putStrLn "Exiting on missing pattern!"
  testFailure

explainFailure :: String -> TestReport -> IO ()
explainFailure explanation report = do
    putStrLn explanation
    putStrLn $ "Events: " ++ show report

testFailure :: IO ()
testFailure = do
  putStrLn "Exiting with failure"
  exitFailure

testSuccess :: IO ()
testSuccess = do
  putStrLn "Exiting with success"
  exitWith ExitSuccess
