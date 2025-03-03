#include "inline.hs"

-- |
-- Module      : Streamly.Internal.Data.Array.Foreign.Mut
-- Copyright   : (c) 2020 Composewell Technologies
-- License     : BSD-3-Clause
-- Maintainer  : streamly@composewell.com
-- Stability   : experimental
-- Portability : GHC
--
-- Unboxed pinned mutable array type for 'Storable' types with an option to use
-- foreign (non-GHC) memory allocators. Fulfils the following goals:
--
-- * Random access (array)
-- * Efficient storage (unboxed)
-- * Performance (unboxed access)
-- * Performance - in-place operations (mutable)
-- * Performance - GC (pinned, mutable)
-- * interfacing with OS (pinned)
-- * Fragmentation control (foreign allocators)
--
-- Stream and Fold APIs allow easy, efficient and convenient operations on
-- arrays.

module Streamly.Internal.Data.Array.Foreign.Mut
    (
      module Streamly.Internal.Data.Array.Foreign.Mut.Type
    , splitOn
    , genSlicesFromLen
    , getSlicesFromLen
    )
where

import Prelude hiding (foldr, length, read, splitAt)

import Streamly.Internal.Data.Array.Foreign.Mut.Type
import qualified Streamly.Internal.Data.Stream.StreamD as D
import Foreign.Storable (Storable)
import Streamly.Internal.Data.Stream.IsStream.Type (SerialT)
import qualified Streamly.Internal.Data.Stream.IsStream.Type as IsStream
import qualified Streamly.Internal.Data.Unfold as Unfold
import Streamly.Internal.Data.Unfold.Type (Unfold(..))
import Control.Monad.IO.Class (MonadIO(..))

-- | Split the array into a stream of slices using a predicate. The element
-- matching the predicate is dropped.
--
-- /Pre-release/
{-# INLINE splitOn #-}
splitOn :: (MonadIO m, Storable a) =>
    (a -> Bool) -> Array a -> SerialT m (Array a)
splitOn predicate arr =
    IsStream.fromStreamD
        $ fmap (\(i, len) -> getSliceUnsafe i len arr)
        $ D.sliceOnSuffix predicate (toStreamD arr)

-- | Generate a stream of array slice descriptors ((index, len)) of specified
-- length from an array, starting from the supplied array index. The last slice
-- may be shorter than the requested length depending on the array length.
--
-- /Pre-release/
{-# INLINE genSlicesFromLen #-}
genSlicesFromLen :: forall m a. (Monad m, Storable a)
    => Int -- ^ from index
    -> Int -- ^ length of the slice
    -> Unfold m (Array a) (Int, Int)
genSlicesFromLen from len =
    let fromThenTo n = (from, from + len, n - 1)
        mkSlice n i = return (i, min len (n - i))
     in Unfold.lmap length
        $ Unfold.mapMWithInput mkSlice
        $ Unfold.lmap fromThenTo Unfold.enumerateFromThenTo

-- | Generate a stream of slices of specified length from an array, starting
-- from the supplied array index. The last slice may be shorter than the
-- requested length depending on the array length.
--
-- /Pre-release/
{-# INLINE getSlicesFromLen #-}
getSlicesFromLen :: forall m a. (Monad m, Storable a)
    => Int -- ^ from index
    -> Int -- ^ length of the slice
    -> Unfold m (Array a) (Array a)
getSlicesFromLen from len =
    let mkSlice arr (i, n) = return $ getSliceUnsafe i n arr
     in Unfold.mapMWithInput mkSlice (genSlicesFromLen from len)
