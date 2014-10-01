{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}

-- | A common problem is the desire to have an action run at a scheduled
-- interval, but only if it is needed. For example, instead of having
-- every web request result in a new @getCurrentTime@ call, we'd like to
-- have a single worker thread run every second, updating an @IORef@.
-- However, if the request frequency is less than once per second, this is
-- a pessimization, and worse, kills idle GC.
--
-- This library allows you to define actions which will either be
-- performed by a dedicated thread or, in times of low volume, will be
-- executed by the calling thread.
module Control.AutoUpdate (
      -- * Type
      UpdateSettings
    , defaultUpdateSettings
      -- * Accessors
    , updateFreq
    , updateSpawnThreshold
    , updateAction
      -- * Creation
    , mkAutoUpdate
    ) where

import Control.AutoUpdate.Util (atomicModifyIORef')
import Control.Concurrent (forkOn, threadDelay, myThreadId, getNumCapabilities, threadCapability)
import Control.Concurrent.STM (TMVar, atomically, newEmptyTMVar, putTMVar, readTMVar)
import Control.Exception (assert, finally, onException, mask_)
import Control.Monad (replicateM, void, when)
import Data.Array (Array, (!), listArray)
import Data.IORef (IORef, newIORef, writeIORef)

-- | Default value for creating an @UpdateSettings@.
--
-- Since 0.1.0
defaultUpdateSettings :: UpdateSettings ()
defaultUpdateSettings = UpdateSettings
    { updateFreq = 1000000
    , updateSpawnThreshold = 3
    , updateAction = return ()
    }

-- | Settings to control how values are updated.
--
-- This should be constructed using @defaultUpdateSettings@ and record
-- update syntax, e.g.:
--
-- @
-- let set = defaultUpdateSettings { updateAction = getCurrentTime }
-- @
--
-- Since 0.1.0
data UpdateSettings a = UpdateSettings
    { updateFreq           :: Int
    -- ^ Microseconds between update calls. Same considerations as
    -- @threadDelay@ apply.
    --
    -- Default: 1 second (1000000)
    --
    -- Since 0.1.0
    , updateSpawnThreshold :: Int
    -- ^ How many times the data must be requested before we decide to
    -- spawn a dedicated thread.
    --
    -- Default: 3
    --
    -- Since 0.1.0
    , updateAction         :: IO a
    -- ^ Action to be performed to get the current value.
    --
    -- Default: does nothing.
    --
    -- Since 0.1.0
    }

data Status a = Manual (TMVar a) {-# UNPACK #-} !Int
                -- Int: Number of times used since we started/switched
                -- off manual updates.
              | Semi (TMVar a)
              | Auto (TMVar a) {-# UNPACK #-} !Int !a
                -- Int: Number of times used since last updated.

type IStatus a = IORef (Status a)
newtype IStatusSet a = IStatusSet (Array Int (IStatus a))

-- | Generate an action which will either read from an automatically
-- updated value, or run the update action in the current thread.
--
-- Since 0.1.0
mkAutoUpdate :: UpdateSettings a -> IO (IO a)
mkAutoUpdate us = do
    n <- getNumCapabilities
    refs <- replicateM n newIStatus
    let !istatusset = IStatusSet $ listArray (0,n-1) refs
    return $! getCurrent us istatusset
  where
    newIStatus = do
        var <- atomically newEmptyTMVar
        newIORef (Manual var 0)

data Action a = Perform | Spawn (TMVar a) | Wait (TMVar a) | UseCache a

-- | Get the current value, either fed from an auto-update thread, or
-- computed manually in the current thread.
--
-- Since 0.1.0
getCurrent :: UpdateSettings a
           -> IStatusSet a
           -> IO a
getCurrent settings@UpdateSettings{..} (IStatusSet istatusset) = do
    (i,_) <- myThreadId >>= threadCapability
    let !istatus = istatusset ! i
    changeAndObtain istatus i `onException` cleanup istatus
  where
    changeAndObtain istatus i = mask_ $
        atomicModifyIORef' istatus change >>= obtain istatus i

    change (Manual var cnt)
      | cnt < updateSpawnThreshold = (Manual var (cnt + 1), Perform)
      | otherwise                  = (Semi var, Spawn var)
    change (Semi var)              = (Semi var, Wait var)
    change (Auto var cnt cur)      = (Auto var (cnt + 1) cur, UseCache cur)

    obtain _ _ Perform           = updateAction
    obtain istatus i (Spawn var) = do
        new <- updateAction
        atomically $ putTMVar var new -- waking up threads in 'Wait'.
        writeIORef istatus (Auto var 0 new)
        void $ forkOn i (spawn settings istatus)
        return new
    -- If the thread to execute putTMVar dies without putTMVar,
    -- an error of dead lock occurs. So, this does not wait forever.
    obtain _ _ (Wait var)        = atomically $ readTMVar var
    obtain _ _ (UseCache cur)    = return cur

spawn :: UpdateSettings a -> IStatus a -> IO ()
spawn UpdateSettings{..} istatus = loop `finally` cleanup istatus
  where
    loop = do
        threadDelay updateFreq
        new <- updateAction
        -- FIXME: this is wasteful.
        -- But this is necessary to avoid deadlock.
        var <- atomically newEmptyTMVar
        again <- atomicModifyIORef' istatus $ change var new
        when again loop

    -- Normal case.
    change var new (Auto oldvar cnt _old)
      | cnt >= 1                   = (Auto oldvar 0 new, True)
      | otherwise                  = (Manual var 0, False)
    -- This case must not happen.
    change var _ _                 = assert False (Manual var 0, False)

cleanup :: IStatus a -> IO ()
cleanup istatus = do
        var <- atomically newEmptyTMVar
        writeIORef istatus $ Manual var 0
