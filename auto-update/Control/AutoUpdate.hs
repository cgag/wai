{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RecordWildCards    #-}

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

import           Control.AutoUpdate.Util (atomicModifyIORef')
import           Control.Concurrent (forkIO, threadDelay)
import           Control.Exception  (assert, finally)
import           Control.Monad      (void, when)
import           Data.IORef         (IORef, newIORef, writeIORef)
import           Control.Concurrent.STM

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

data Status a = AutoUpdated
                    (TMVar a)
                    {-# UNPACK #-} !Int
                    -- Number of times used since last updated.
                    !a
              | Spawning (TMVar a)
              | ManualUpdates
                    (TMVar a)
                    {-# UNPACK #-} !Int
                    -- Number of times used since we started/switched
                    -- off manual updates.

-- | Generate an action which will either read from an automatically
-- updated value, or run the update action in the current thread.
--
-- Since 0.1.0
mkAutoUpdate :: UpdateSettings a -> IO (IO a)
mkAutoUpdate us = do
    var <- atomically newEmptyTMVar
    istatus <- newIORef $ ManualUpdates var 0
    return $! getCurrent us istatus

data Action a = Manual | Spawn (TMVar a) | Wait (TMVar a) | Return a

-- | Get the current value, either fed from an auto-update thread, or
-- computed manually in the current thread.
--
-- Since 0.1.0
getCurrent :: UpdateSettings a
           -> IORef (Status a) -- ^ mutable state
           -> IO a
getCurrent settings@UpdateSettings{..} istatus =
    atomicModifyIORef' istatus change >>= switch
  where
    change (ManualUpdates var cnt)
      | cnt < updateSpawnThreshold   = (ManualUpdates var (cnt + 1), Manual)
      | otherwise                    = (Spawning var, Spawn var)
    change (Spawning var)            = (Spawning var, Wait var)
    change (AutoUpdated var cnt cur) = (AutoUpdated var (cnt + 1) cur, Return cur)

    switch Manual       = updateAction
    switch (Spawn var)  = do
        new <- updateAction
        atomically $ putTMVar var new
        writeIORef istatus (AutoUpdated var 0 new)
        void . forkIO $ spawn settings istatus
        return new
    switch (Wait var)   = atomically $ readTMVar var
    switch (Return cur) = return cur

spawn :: UpdateSettings a -> IORef (Status a) -> IO ()
spawn UpdateSettings{..} istatus = loop `finally` cleanup
  where
    loop = do
        threadDelay updateFreq
        new <- updateAction
        var <- atomically newEmptyTMVar -- FIXME: this is wasteful.
        again <- atomicModifyIORef' istatus $ change var new
        when again loop

    -- Normal case.
    change var new (AutoUpdated oldvar cnt _old)
      | cnt >= 1                     = (AutoUpdated oldvar 0 new, True)
      | otherwise                    = (ManualUpdates var 0, False)
    -- This case must not happen.
    change _ _ (ManualUpdates cnt oldvar) = assert False (ManualUpdates cnt oldvar, False)
    change var _ (Spawning _)             = assert False (ManualUpdates var 0, False)

    cleanup = do
        var <- atomically newEmptyTMVar
        writeIORef istatus $ ManualUpdates var 0
