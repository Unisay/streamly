#include "inline.hs"

-- |
-- Module      : Streamly.Internal.FileSystem.Dir
-- Copyright   : (c) 2018 Composewell Technologies
--
-- License     : BSD3
-- Maintainer  : streamly@composewell.com
-- Stability   : pre-release
-- Portability : GHC

module Streamly.Internal.FileSystem.Dir
    (
    -- ** Read from Directory
      read
    , readFiles
    , readDirs
    , readEither
    -- , readWithBufferOf

    , toStream
    , toEither
    , toFiles
    , toDirs
      {-
    , toStreamWithBufferOf

    , readChunks
    , readChunksWithBufferOf

    , toChunksWithBufferOf
    , toChunks

    , write
    , writeWithBufferOf

    -- Byte stream write (Streams)
    , fromStream
    , fromStreamWithBufferOf

    -- -- * Array Write
    , writeArray
    , writeChunks
    , writeChunksWithBufferOf

    -- -- * Array stream Write
    , fromChunks
    , fromChunksWithBufferOf
    -}
    )
where

import Control.Monad.IO.Class (MonadIO(..))
import Data.Either (isRight, isLeft)
-- import Data.Word (Word8)
-- import Foreign.ForeignPtr (withForeignPtr)
-- import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
-- import Foreign.Ptr (minusPtr, plusPtr)
-- import Foreign.Storable (Storable(..))
-- import GHC.ForeignPtr (mallocPlainForeignPtrBytes)
-- import System.IO (Handle, hGetBufSome, hPutBuf)
import Prelude hiding (read)

-- import Streamly.Data.Fold (Fold)
import Streamly.Internal.BaseCompat (fromLeft, fromRight)
import Streamly.Internal.Data.Unfold.Type (Unfold(..))
-- import Streamly.Internal.Data.Array.Foreign.Type
--        (Array(..), writeNUnsafe, defaultChunkSize, shrinkToFit,
--         lpackArraysChunksOf)
-- import Streamly.Internal.Data.Stream.Serial (SerialT)
import Streamly.Internal.Data.Stream.IsStream.Type (IsStream)
-- import Streamly.String (encodeUtf8, decodeUtf8, foldLines)

-- import qualified Streamly.Data.Fold as FL
-- import qualified Streamly.Internal.Data.Fold.Type as FL
import qualified Streamly.Internal.Data.Unfold as UF
-- import qualified Streamly.Internal.Data.Array.Stream.Foreign as AS
import qualified Streamly.Internal.Data.Stream.IsStream as S
-- import qualified Streamly.Data.Array.Foreign as A
-- import qualified Streamly.Internal.Data.Stream.StreamD.Type as D
import qualified System.Directory as Dir

{-
{-# INLINABLE readArrayUpto #-}
readArrayUpto :: Int -> Handle -> IO (Array Word8)
readArrayUpto size h = do
    ptr <- mallocPlainForeignPtrBytes size
    -- ptr <- mallocPlainForeignPtrAlignedBytes size (alignment (undefined :: Word8))
    withForeignPtr ptr $ \p -> do
        n <- hGetBufSome h p size
        let v = Array
                { aStart = ptr
                , aEnd   = p `plusPtr` n
                , aBound = p `plusPtr` size
                }
        -- XXX shrink only if the diff is significant
        shrinkToFit v

-------------------------------------------------------------------------------
-- Stream of Arrays IO
-------------------------------------------------------------------------------

-- | @toChunksWithBufferOf size h@ reads a stream of arrays from file handle @h@.
-- The maximum size of a single array is specified by @size@. The actual size
-- read may be less than or equal to @size@.
{-# INLINABLE _toChunksWithBufferOf #-}
_toChunksWithBufferOf :: (IsStream t, MonadIO m)
    => Int -> Handle -> t m (Array Word8)
_toChunksWithBufferOf size h = go
  where
    -- XXX use cons/nil instead
    go = mkStream $ \_ yld _ stp -> do
        arr <- liftIO $ readArrayUpto size h
        if A.length arr == 0
        then stp
        else yld arr go

-- | @toChunksWithBufferOf size handle@ reads a stream of arrays from the file
-- handle @handle@.  The maximum size of a single array is limited to @size@.
-- The actual size read may be less than or equal to @size@.
--
-- @since 0.7.0
{-# INLINE_NORMAL toChunksWithBufferOf #-}
toChunksWithBufferOf :: (IsStream t, MonadIO m) => Int -> Handle -> t m (Array Word8)
toChunksWithBufferOf size h = D.fromStreamD (D.Stream step ())
  where
    {-# INLINE_LATE step #-}
    step _ _ = do
        arr <- liftIO $ readArrayUpto size h
        return $
            case A.length arr of
                0 -> D.Stop
                _ -> D.Yield arr ()

-- | Unfold the tuple @(bufsize, handle)@ into a stream of 'Word8' arrays.
-- Read requests to the IO device are performed using a buffer of size
-- @bufsize@.  The size of an array in the resulting stream is always less than
-- or equal to @bufsize@.
--
-- @since 0.7.0
{-# INLINE_NORMAL readChunksWithBufferOf #-}
readChunksWithBufferOf :: MonadIO m => Unfold m (Int, Handle) (Array Word8)
readChunksWithBufferOf = Unfold step return
    where
    {-# INLINE_LATE step #-}
    step (size, h) = do
        arr <- liftIO $ readArrayUpto size h
        return $
            case A.length arr of
                0 -> D.Stop
                _ -> D.Yield arr (size, h)

-- XXX read 'Array a' instead of Word8
--
-- | @toChunks handle@ reads a stream of arrays from the specified file
-- handle.  The maximum size of a single array is limited to
-- @defaultChunkSize@. The actual size read may be less than or equal to
-- @defaultChunkSize@.
--
-- > toChunks = toChunksWithBufferOf defaultChunkSize
--
-- @since 0.7.0
{-# INLINE toChunks #-}
toChunks :: (IsStream t, MonadIO m) => Handle -> t m (Array Word8)
toChunks = toChunksWithBufferOf defaultChunkSize

-- | Unfolds a handle into a stream of 'Word8' arrays. Requests to the IO
-- device are performed using a buffer of size
-- 'Streamly.Internal.Data.Array.Foreign.Type.defaultChunkSize'. The
-- size of arrays in the resulting stream are therefore less than or equal to
-- 'Streamly.Internal.Data.Array.Foreign.Type.defaultChunkSize'.
--
-- @since 0.7.0
{-# INLINE readChunks #-}
readChunks :: MonadIO m => Unfold m Handle (Array Word8)
readChunks = UF.supplyFirst readChunksWithBufferOf defaultChunkSize

-------------------------------------------------------------------------------
-- Read File to Stream
-------------------------------------------------------------------------------

-- TODO for concurrent streams implement readahead IO. We can send multiple
-- read requests at the same time. For serial case we can use async IO. We can
-- also control the read throughput in mbps or IOPS.

-- | Unfolds the tuple @(bufsize, handle)@ into a byte stream, read requests
-- to the IO device are performed using buffers of @bufsize@.
--
-- @since 0.7.0
{-# INLINE readWithBufferOf #-}
readWithBufferOf :: MonadIO m => Unfold m (Int, Handle) Word8
readWithBufferOf = UF.many readChunksWithBufferOf A.read

-- | @toStreamWithBufferOf bufsize handle@ reads a byte stream from a file
-- handle, reads are performed in chunks of up to @bufsize@.
--
-- /Pre-release/
{-# INLINE toStreamWithBufferOf #-}
toStreamWithBufferOf :: (IsStream t, MonadIO m) => Int -> Handle -> t m Word8
toStreamWithBufferOf chunkSize h = AS.concat $ toChunksWithBufferOf chunkSize h
-}

-- XXX exception handling
--  | Raw read of a directory
--
--  /Internal/
--
{-# INLINE read #-}
read :: MonadIO m => Unfold m String String
read =
    -- XXX use proper streaming read of the dir
    UF.lmapM (liftIO . Dir.getDirectoryContents) UF.fromList

-- XXX We can use a more general mechanism to filter the contents of a
-- directory. We can just stat each child and pass on the stat information. We
-- can then use that info to do a general filtering. "find" like filters can be
-- created.

-- | Read directories as Left and files as Right. Filter out "." and ".."
-- entries.
--
--  /Internal/
--
{-# INLINE readEither #-}
readEither :: MonadIO m => Unfold m String (Either String String)
readEither =
      UF.mapMWithInput classify
    $ UF.filter (\x -> x /= "." && x /= "..")
    -- XXX use proper streaming read of the dir
    $ UF.lmapM (liftIO . Dir.getDirectoryContents) UF.fromList
    where
    classify dir x = do
        r <- liftIO $ Dir.doesDirectoryExist (dir ++ "/" ++ x)
        return $ if r then Left x else Right x

--
-- | Read files only.
--
--  /Internal/
--
{-# INLINE readFiles #-}
readFiles :: MonadIO m => Unfold m String String
readFiles = UF.map (fromRight undefined) $ UF.filter isRight readEither

-- | Read directories only. Filter out "." and ".." entries.
--
--  /Internal/
--
{-# INLINE readDirs #-}
readDirs :: MonadIO m => Unfold m String String
readDirs = UF.map (fromLeft undefined) $ UF.filter isLeft readEither

-- | Raw read of a directory.
--
-- /Pre-release/
{-# INLINE toStream #-}
toStream :: (IsStream t, MonadIO m) => String -> t m String
toStream = S.unfold read

-- | Read directories as Left and files as Right. Filter out "." and ".."
-- entries.
--
-- /Pre-release/
{-# INLINE toEither #-}
toEither :: (IsStream t, MonadIO m)
    => String -> t m (Either String String)
toEither = S.unfold readEither

-- | Read files only.
--
--  /Internal/
--
{-# INLINE toFiles #-}
toFiles :: (IsStream t, MonadIO m) => String -> t m String
toFiles = S.unfold readFiles

-- | Read directories only.
--
--  /Internal/
--
{-# INLINE toDirs #-}
toDirs :: (IsStream t, MonadIO m) => String -> t m String
toDirs = S.unfold readDirs

{-
-------------------------------------------------------------------------------
-- Writing
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Array IO (output)
-------------------------------------------------------------------------------

-- | Write an 'Array' to a file handle.
--
-- @since 0.7.0
{-# INLINABLE writeArray #-}
writeArray :: Storable a => Handle -> Array a -> IO ()
writeArray _ arr | A.length arr == 0 = return ()
writeArray h Array{..} = withForeignPtr aStart $ \p -> hPutBuf h p aLen
    where
    aLen =
        let p = unsafeForeignPtrToPtr aStart
        in aEnd `minusPtr` p

-------------------------------------------------------------------------------
-- Stream of Arrays IO
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Writing
-------------------------------------------------------------------------------

-- | Write a stream of arrays to a handle.
--
-- @since 0.7.0
{-# INLINE fromChunks #-}
fromChunks :: (MonadIO m, Storable a)
    => Handle -> SerialT m (Array a) -> m ()
fromChunks h m = S.mapM_ (liftIO . writeArray h) m

-- | @fromChunksWithBufferOf bufsize handle stream@ writes a stream of arrays
-- to @handle@ after coalescing the adjacent arrays in chunks of @bufsize@.
-- The chunk size is only a maximum and the actual writes could be smaller as
-- we do not split the arrays to fit exactly to the specified size.
--
-- @since 0.7.0
{-# INLINE fromChunksWithBufferOf #-}
fromChunksWithBufferOf :: (MonadIO m, Storable a)
    => Int -> Handle -> SerialT m (Array a) -> m ()
fromChunksWithBufferOf n h xs = fromChunks h $ AS.compact n xs

-- | @fromStreamWithBufferOf bufsize handle stream@ writes @stream@ to @handle@
-- in chunks of @bufsize@.  A write is performed to the IO device as soon as we
-- collect the required input size.
--
-- @since 0.7.0
{-# INLINE fromStreamWithBufferOf #-}
fromStreamWithBufferOf :: MonadIO m => Int -> Handle -> SerialT m Word8 -> m ()
fromStreamWithBufferOf n h m = fromChunks h $ S.arraysOf n m
-- fromStreamWithBufferOf n h m = fromChunks h $ AS.arraysOf n m

-- > write = 'writeWithBufferOf' A.defaultChunkSize
--
-- | Write a byte stream to a file handle. Accumulates the input in chunks of
-- up to 'Streamly.Internal.Data.Array.Foreign.Type.defaultChunkSize' before writing.
--
-- NOTE: This may perform better than the 'write' fold, you can try this if you
-- need some extra perf boost.
--
-- @since 0.7.0
{-# INLINE fromStream #-}
fromStream :: MonadIO m => Handle -> SerialT m Word8 -> m ()
fromStream = fromStreamWithBufferOf defaultChunkSize

-- | Write a stream of arrays to a handle. Each array in the stream is written
-- to the device as a separate IO request.
--
-- @since 0.7.0
{-# INLINE writeChunks #-}
writeChunks :: (MonadIO m, Storable a) => Handle -> Fold m (Array a) ()
writeChunks h = FL.drainBy (liftIO . writeArray h)

-- | @writeChunksWithBufferOf bufsize handle@ writes a stream of arrays
-- to @handle@ after coalescing the adjacent arrays in chunks of @bufsize@.
-- We never split an array, if a single array is bigger than the specified size
-- it emitted as it is. Multiple arrays are coalesed as long as the total size
-- remains below the specified size.
--
-- @since 0.7.0
{-# INLINE writeChunksWithBufferOf #-}
writeChunksWithBufferOf :: (MonadIO m, Storable a)
    => Int -> Handle -> Fold m (Array a) ()
writeChunksWithBufferOf n h = lpackArraysChunksOf n (writeChunks h)

-- GHC buffer size dEFAULT_FD_BUFFER_SIZE=8192 bytes.
--
-- XXX test this
-- Note that if you use a chunk size less than 8K (GHC's default buffer
-- size) then you are advised to use 'NOBuffering' mode on the 'Handle' in case you
-- do not want buffering to occur at GHC level as well. Same thing applies to
-- writes as well.

-- | @writeWithBufferOf reqSize handle@ writes the input stream to @handle@.
-- Bytes in the input stream are collected into a buffer until we have a chunk
-- of @reqSize@ and then written to the IO device.
--
-- @since 0.7.0
{-# INLINE writeWithBufferOf #-}
writeWithBufferOf :: MonadIO m => Int -> Handle -> Fold m Word8 ()
writeWithBufferOf n h = FL.chunksOf n (writeNUnsafe n) (writeChunks h)

-- > write = 'writeWithBufferOf' A.defaultChunkSize
--
-- | Write a byte stream to a file handle. Accumulates the input in chunks of
-- up to 'Streamly.Internal.Data.Array.Foreign.Type.defaultChunkSize' before writing
-- to the IO device.
--
-- @since 0.7.0
{-# INLINE write #-}
write :: MonadIO m => Handle -> Fold m Word8 ()
write = writeWithBufferOf defaultChunkSize
-}
