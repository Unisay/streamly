-- Some code snippets are adapted from the fsnotify package.
-- http://hackage.haskell.org/package/fsnotify-0.3.0.1/
--
-- |
-- Module      : Streamly.Internal.FileSystem.Event.Windows
-- Copyright   : (c) 2020 Composewell Technologies
--               (c) 2012, Mark Dittmer
-- License     : BSD-3-Clause
-- Maintainer  : streamly@composewell.com
-- Stability   : pre-release
-- Portability : GHC
--
-- =Overview
--
-- Use 'watchTrees'or 'watchPaths' with a list of file system paths you want to
-- watch as argument. It returns a stream of 'Event' representing the file
-- system events occurring under the watched paths.
--
-- @
-- {-\# LANGUAGE MagicHash #-}
-- Stream.mapM_ (putStrLn . 'showEvent') $ 'watchTrees' [Array.fromCString\# "path"#]
-- @
--
-- 'Event' is an opaque type. Accessor functions (e.g. 'showEvent' above)
-- provided in this module are used to determine the attributes of the event.
--
-- =Design notes
--
-- For Windows reference documentation see:
--
-- * <https://docs.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-file_notify_information file notify information>
-- * <https://docs.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-readdirectorychangesw read directory changes>
--
-- We try to keep the macOS\/Linux/Windows event handling APIs and defaults
-- semantically and syntactically as close as possible.
--
-- =Availability
--
-- As per the Windows reference docs, the fs event notification API is
-- available in:
--
-- * Minimum supported client: Windows XP [desktop apps | UWP apps]
-- * Minimum supported server: Windows Server 2003 [desktop apps | UWP apps

module Streamly.Internal.FileSystem.Event.Windows
    (
    -- * Subscribing to events

    -- ** Default configuration
      Config
    , Toggle (..)
    , defaultConfig

    -- ** Watch Behavior
    , setRecursiveMode

    -- ** Events of Interest
    , setRootMoved
    , setModifiedFileName
    , setModifiedAttribute
    , setModifiedSize
    , setModifiedLastWrite
    , setModifiedSecurity

    -- ** Watch APIs
    , watch
    , watchRecursive
    , watchWith

    -- * Handling Events
    , Event(..)
    , getRoot
    , getRelPath
    , getAbsPath

    -- ** Item CRUD events
    , isCreated
    , isDeleted
    , isModified
    , isMoved
    , isMovedFrom
    , isMovedTo

    -- ** Exception Conditions
    , isEventsLost

    -- * Debugging
    , showEvent
    )
where

import Control.Monad.IO.Class (MonadIO(liftIO))
import Data.Bits ((.|.), (.&.), complement)
import Data.Functor.Identity (runIdentity)
import Data.List.NonEmpty (NonEmpty)
import Data.Word (Word8)
import Foreign.C.String (peekCWStringLen)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Storable (peekByteOff)
import Foreign.Ptr (Ptr, FunPtr, castPtr, nullPtr, nullFunPtr, plusPtr)
import Streamly.Prelude (SerialT, parallel)
import System.Win32.File
    ( FileNotificationFlag
    , LPOVERLAPPED
    , closeHandle
    , createFile
    , fILE_FLAG_BACKUP_SEMANTICS
    , fILE_LIST_DIRECTORY
    , fILE_NOTIFY_CHANGE_FILE_NAME
    , fILE_NOTIFY_CHANGE_DIR_NAME
    , fILE_NOTIFY_CHANGE_ATTRIBUTES
    , fILE_NOTIFY_CHANGE_SIZE
    , fILE_NOTIFY_CHANGE_LAST_WRITE
    , fILE_NOTIFY_CHANGE_SECURITY
    , fILE_SHARE_READ
    , fILE_SHARE_WRITE
    , oPEN_EXISTING
    )
import System.Win32.Types (BOOL, DWORD, HANDLE, LPVOID, LPDWORD, failIfFalse_)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Streamly.Internal.Data.Stream.IsStream as S
import qualified Streamly.Internal.Unicode.Stream as U
import qualified Streamly.Internal.Unicode.Utf8 as UTF8
import qualified Streamly.Internal.Data.Array.Foreign as A
import Streamly.Internal.Data.Array.Foreign (Array)

-- | Watch configuration, used to specify the events of interest and the
-- behavior of the watch.
--
-- /Pre-release/
--
data Config = Config
    { watchRec :: BOOL
    , createFlags :: DWORD
    }

-------------------------------------------------------------------------------
-- Boolean settings
-------------------------------------------------------------------------------

-- | Whether a setting is 'On' or 'Off'.
--
-- /Pre-release/
--
data Toggle = On | Off

setFlag :: DWORD -> Toggle -> Config -> Config
setFlag mask status cfg@Config{..} =
    let flags =
            case status of
                On -> createFlags .|. mask
                Off -> createFlags .&. complement mask
    in cfg {createFlags = flags}

-- | Set watch event on directory recursively.
--
-- /default: On/
--
-- /Pre-release/
--
setRecursiveMode :: BOOL -> Config -> Config
setRecursiveMode rec cfg@Config{} = cfg {watchRec = rec}

-- | Report when a file name is modified.
--
-- /default: On/
--
-- /Pre-release/
--
setModifiedFileName :: Toggle -> Config -> Config
setModifiedFileName = setFlag fILE_NOTIFY_CHANGE_FILE_NAME

-- | Report when a directory name is modified.
--
-- /default: On/
--
-- /Pre-release/
--
setRootMoved :: Toggle -> Config -> Config
setRootMoved = setFlag fILE_NOTIFY_CHANGE_DIR_NAME

-- | Report when a file attribute is modified.
--
-- /default: On/
--
-- /Pre-release/
--
setModifiedAttribute :: Toggle -> Config -> Config
setModifiedAttribute = setFlag fILE_NOTIFY_CHANGE_ATTRIBUTES

-- | Report when a file size is changed.
--
-- /default: On/
--
-- /Pre-release/
--
setModifiedSize :: Toggle -> Config -> Config
setModifiedSize = setFlag fILE_NOTIFY_CHANGE_SIZE

-- | Report when a file last write time is changed.
--
-- /default: On/
--
-- /Pre-release/
--
setModifiedLastWrite :: Toggle -> Config -> Config
setModifiedLastWrite = setFlag fILE_NOTIFY_CHANGE_LAST_WRITE

-- | Report when a file Security attributes is changed.
--
-- /default: On/
--
-- /Pre-release/
--
setModifiedSecurity :: Toggle -> Config -> Config
setModifiedSecurity = setFlag fILE_NOTIFY_CHANGE_SECURITY

-- | Set all events 'On' or 'Off'.
--
-- /default: On/
--
-- /Pre-release/
--
setAllEvents :: Toggle -> Config -> Config
setAllEvents s =
     setModifiedFileName s
    . setRootMoved s
    . setModifiedAttribute s
    . setModifiedSize s
    . setModifiedLastWrite s
    . setModifiedSecurity s

defaultConfig :: Config
defaultConfig = setAllEvents On $ Config {watchRec = True, createFlags = 0}

getConfigFlag :: Config -> DWORD
getConfigFlag Config{..} = createFlags

getConfigRecMode :: Config -> BOOL
getConfigRecMode Config{..} = watchRec

data Event = Event
    { eventFlags :: DWORD
    , eventRelPath :: String
    , eventRootPath :: String
    , totalBytes :: DWORD
    } deriving (Show, Ord, Eq)

-- For reference documentation see:
--
-- See https://docs.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-file_notify_information
data FILE_NOTIFY_INFORMATION = FILE_NOTIFY_INFORMATION
    { fniNextEntryOffset :: DWORD
    , fniAction :: DWORD
    , fniFileName :: String
    } deriving Show

type LPOVERLAPPED_COMPLETION_ROUTINE =
    FunPtr ((DWORD, DWORD, LPOVERLAPPED) -> IO ())

-- | A handle for a watch.
getWatchHandle :: FilePath -> IO (HANDLE, FilePath)
getWatchHandle dir = do
    h <- createFile dir
        -- Access mode
        fILE_LIST_DIRECTORY
        -- Share mode
        (fILE_SHARE_READ .|. fILE_SHARE_WRITE)
        -- Security attributes
        Nothing
        -- Create mode, we want to look at an existing directory
        oPEN_EXISTING
        -- File attribute, NOT using OVERLAPPED since we work synchronously
        fILE_FLAG_BACKUP_SEMANTICS
        -- No template file
        Nothing
    return (h, dir)

-- For reference documentation see:
--
-- See https://docs.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-readdirectorychangesw
-- Note that this API uses UTF-16 for file system paths:
-- 1. https://docs.microsoft.com/en-us/windows/win32/intl/unicode-in-the-windows-api
-- 2. https://docs.microsoft.com/en-us/windows/win32/intl/unicode
foreign import ccall safe
    "windows.h ReadDirectoryChangesW" c_ReadDirectoryChangesW ::
           HANDLE
        -> LPVOID
        -> DWORD
        -> BOOL
        -> DWORD
        -> LPDWORD
        -> LPOVERLAPPED
        -> LPOVERLAPPED_COMPLETION_ROUTINE
        -> IO BOOL

readDirectoryChangesW ::
       HANDLE
    -> Ptr FILE_NOTIFY_INFORMATION
    -> DWORD
    -> BOOL
    -> FileNotificationFlag
    -> LPDWORD
    -> IO ()
readDirectoryChangesW h buf bufSize wst f br =
    let res = c_ReadDirectoryChangesW
                    h (castPtr buf) bufSize wst f br nullPtr nullFunPtr
     in failIfFalse_ "ReadDirectoryChangesW" res

peekFNI :: Ptr FILE_NOTIFY_INFORMATION -> IO FILE_NOTIFY_INFORMATION
peekFNI buf = do
    neof <- peekByteOff buf 0
    acti <- peekByteOff buf 4
    fnle <- peekByteOff buf 8
    -- Note: The path is UTF-16 encoded C WChars, peekCWStringLen converts
    -- UTF-16 to UTF-32 Char String
    fnam <- peekCWStringLen
        -- start of array
        (buf `plusPtr` 12,
        -- fnle is the length in *bytes*, and a WCHAR is 2 bytes
        fromEnum (fnle :: DWORD) `div` 2)
    return $ FILE_NOTIFY_INFORMATION neof acti fnam

readChangeEvents ::
    Ptr FILE_NOTIFY_INFORMATION -> String -> DWORD -> IO [Event]
readChangeEvents pfni root bytesRet = do
    fni <- peekFNI pfni
    let entry = Event
            { eventFlags = fniAction fni
            , eventRelPath = fniFileName fni
            , eventRootPath = root
            , totalBytes = bytesRet
            }
        nioff = fromEnum $ fniNextEntryOffset fni
    entries <-
        if nioff == 0
        then return []
        else readChangeEvents (pfni `plusPtr` nioff) root bytesRet
    return $ entry : entries

readDirectoryChanges ::
    String -> HANDLE -> Bool -> FileNotificationFlag -> IO [Event]
readDirectoryChanges root h wst mask = do
    let maxBuf = 63 * 1024
    allocaBytes maxBuf $ \buffer -> do
        alloca $ \bret -> do
            readDirectoryChangesW h buffer (toEnum maxBuf) wst mask bret
            bytesRet <- peekByteOff bret 0
            readChangeEvents buffer root bytesRet

type FileAction = DWORD

fILE_ACTION_ADDED             :: FileAction
fILE_ACTION_ADDED             =  1

fILE_ACTION_REMOVED           :: FileAction
fILE_ACTION_REMOVED           =  2

fILE_ACTION_MODIFIED          :: FileAction
fILE_ACTION_MODIFIED          =  3

fILE_ACTION_RENAMED_OLD_NAME  :: FileAction
fILE_ACTION_RENAMED_OLD_NAME  =  4

fILE_ACTION_RENAMED_NEW_NAME  :: FileAction
fILE_ACTION_RENAMED_NEW_NAME  =  5

eventStreamAggr :: (HANDLE, FilePath, Config) -> SerialT IO Event
eventStreamAggr (handle, rootPath, cfg) =  do
    let recMode = getConfigRecMode cfg
        flagMasks = getConfigFlag cfg
    S.concatMap S.fromList $ S.repeatM
        $ readDirectoryChanges rootPath handle recMode flagMasks

pathsToHandles ::
    NonEmpty FilePath -> Config -> SerialT IO (HANDLE, FilePath, Config)
pathsToHandles paths cfg = do
    let pathStream = S.fromList (NonEmpty.toList paths)
        st2 = S.mapM getWatchHandle pathStream
    S.map (\(h, f) -> (h, f, cfg)) st2

-------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------

utf8ToString :: Array Word8 -> FilePath
utf8ToString = runIdentity . S.toList . U.decodeUtf8 . A.toStream

utf8ToStringList :: NonEmpty (Array Word8) -> NonEmpty FilePath
utf8ToStringList = NonEmpty.map utf8ToString

-- | Close a Directory handle.
--
closePathHandleStream :: SerialT IO (HANDLE, FilePath, Config) -> IO ()
closePathHandleStream = S.mapM_ (\(h, _, _) -> closeHandle h)

-- XXX
-- Document the path treatment for Linux/Windows/macOS modules.
-- Remove the utf-8 encoding requirement of paths? It can be encoding agnostic
-- "\" separated bytes, the application can decide what encoding to use.
-- Instead of always using widechar (-W) APIs can we call the underlying APIs
-- based on the configured code page?
-- https://docs.microsoft.com/en-us/windows/uwp/design/globalizing/use-utf8-code-page
--
-- | Start monitoring a list of file system paths for file system events with
-- the supplied configuration modifier operation over the' defaultConfig'. The
-- paths could be files or directories.
--
-- When recursive mode is True and the path is a directory, the whole directory
-- tree under it is watched recursively.  When recursive mode is False and the
-- path is a directory, only the files and directories directly under the
-- watched directory are monitored, contents of subdirectories are not
-- monitored.  Monitoring starts from the current time onwards. The paths are
-- specified as encoded 'Array' of 'Word8'.
--
-- @
-- watchWith
--  ('setModifiedAttribute' On . 'setModifiedLastWrite' Off)
--  [Array.fromCString\# "dir"#]
-- @
--
-- /Pre-release/
--
watchWith :: (Config -> Config) -> NonEmpty (Array Word8) -> SerialT IO Event
watchWith f paths =
     S.bracket before after (S.concatMapWith parallel eventStreamAggr)

    where

    before = return $ pathsToHandles (utf8ToStringList paths) $ f defaultConfig
    after = liftIO . closePathHandleStream

-- | Same as 'watchWith' using 'defaultConfig' and recursive mode.
--
-- >>> watchRecursive = watchWith id
--
-- /Pre-release/
--
watchRecursive :: NonEmpty (Array Word8) -> SerialT IO Event
watchRecursive = watchWith id

-- | Same as 'watchWith' using defaultConfig and non-recursive mode.
--
-- /Pre-release/
--
watch :: NonEmpty (Array Word8) -> SerialT IO Event
watch = watchWith (setRecursiveMode False)

getFlag :: DWORD -> Event -> Bool
getFlag mask Event{..} = eventFlags == mask

-- XXX Change the type to Array Word8 to make it compatible with other APIs.
--
-- | Get the file system object path for which the event is generated, relative
-- to the watched root. The path is a UTF-8 encoded array of bytes.
--
-- /Pre-release/
--
getRelPath :: Event -> Array Word8
getRelPath Event{..} = (UTF8.toArray . UTF8.pack) eventRelPath

-- XXX Change the type to Array Word8 to make it compatible with other APIs.
--
-- | Get the watch root directory to which this event belongs.
--
-- /Pre-release/
--
getRoot :: Event -> Array Word8
getRoot Event{..} = (UTF8.toArray . UTF8.pack) eventRootPath

getAbsPath :: Event -> Array Word8
getAbsPath ev = getRoot ev <> A.fromCString# "\\"# <> (getRelPath ev)

-- XXX need to document the exact semantics of these.
--
-- | File/directory created in watched directory.
-- ** In non-recursive mode
-- @
-- When a file or directory is created, Created and Modified events are
-- generated for corresponding file or directory. Parent directory will not
-- generate any events.
--
-- When a nested directory is created following events are generated:
-- Created event for the directory created.
-- Modified event for the directory created.
-- Modified event for each entry inside it.
-- If a nested directory contains 5 entries on top level then we will get
-- one Created and six Modified events for the created top directory path.
-- @
--
-- ** In recursive mode
-- @
-- When a file is created we get following events:
-- Created event for the file got created.
-- Modified event for the file got created.
-- Modified event for the parent directory.
-- @
--
-- @
-- When an empty directory is created we get following events:
-- Created event for the directory got created.
-- Modified event for the parent directory.
-- @
--
-- @
-- When a nested directory is created we get
-- following events:
-- Created and Modified events for all the files and subdirectories
-- recursively inside the given directory.
-- Modified event for the parent directory.
-- @
--
-- /Pre-release/
--
isCreated :: Event -> Bool
isCreated = getFlag fILE_ACTION_ADDED

-- | File/directory deleted from watched directory.
-- ** In non-recursive mode:
-- Deleted event is generated for object deleted from watched directory.
-- No events are generated for nested objects.
--
-- ** In recursive mode:
-- If a nested directory is deleted Modified events are received for nested
-- sub-directories recursively. No events are generated for nested files.
-- /Pre-release/
--
isDeleted :: Event -> Bool
isDeleted = getFlag fILE_ACTION_REMOVED

-- | Generated for the original path when an object is moved from under a
-- monitored directory.
-- In recursive mode Modified events is generated for parent directory.
--
-- /Pre-release/
--
isMovedFrom :: Event -> Bool
isMovedFrom = getFlag fILE_ACTION_RENAMED_OLD_NAME

-- | Generated for the new path when an object is moved under a monitored
-- directory.
-- In recursive mode Modified events is generated for parent directory.
--
-- /Pre-release/
--
isMovedTo :: Event -> Bool
isMovedTo = getFlag fILE_ACTION_RENAMED_NEW_NAME

-- | Generated for a path that is moved from or moved to the monitored
-- directory.
--
-- >>> isMoved ev = isMovedFrom ev || isMovedTo ev
--
-- /Occurs only for an object inside the watched directory/
--
-- /Pre-release/
--
isMoved :: Event -> Bool
isMoved ev = isMovedFrom ev || isMovedTo ev

-- XXX This event is generated only for files and not directories?
--
-- | Determine whether the event indicates modification of an object within the
-- monitored path.
-- In non-recursive mode Modified event is not generated for a directory.
-- In recursive mode Modified event is generated for parent directory if a file
-- or directory is created or renamed.
-- /Pre-release/
--
isModified :: Event -> Bool
isModified = getFlag fILE_ACTION_MODIFIED

-- |  If the buffer overflows, entire contents of the buffer are discarded,
-- therefore, events are lost.  The user application must scan everything under
-- the watched paths to know the current state.
--
-- /Pre-release/
--
isEventsLost :: Event -> Bool
isEventsLost Event{..} = totalBytes == 0

-------------------------------------------------------------------------------
-- Debugging
-------------------------------------------------------------------------------

-- | Convert an 'Event' record to a String representation.
showEvent :: Event -> String
showEvent ev@Event{..} =
        "--------------------------"
    ++ "\nRoot = " ++ utf8ToString (getRoot ev)
    ++ "\nPath = " ++ utf8ToString (getRelPath ev)
    ++ "\ngetAbsPath = " ++ utf8ToString (getAbsPath ev)
    ++ "\nFlags " ++ show eventFlags
    ++ showev isEventsLost "Overflow"
    ++ showev isCreated "Created"
    ++ showev isDeleted "Deleted"
    ++ showev isModified "Modified"
    ++ showev isMovedFrom "MovedFrom"
    ++ showev isMovedTo "MovedTo"
    ++ "\n"

    where showev f str = if f ev then "\n" ++ str else ""
