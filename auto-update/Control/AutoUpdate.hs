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
import           Data.IORef         (IORef, newIORef, writeIORef, readIORef)
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

data Status = Auto | Spawning | Manual
data Action = Exec | Spawn | Wait | Return

-- | Generate an action which will either read from an automatically
-- updated value, or run the update action in the current thread.
--
-- Since 0.1.0
mkAutoUpdate :: UpdateSettings a -> IO (IO a)
mkAutoUpdate settings = do
    var <- atomically newEmptyTMVar
    stateref <- newIORef Manual
    cntref <- newIORef 0
    return $! getCurrent settings var stateref cntref

-- | Get the current value, either fed from an auto-update thread, or
-- computed manually in the current thread.
--
-- Since 0.1.0
getCurrent :: UpdateSettings a
           -> TMVar a
           -> IORef Status
           -> IORef Int
           -> IO a
getCurrent settings@UpdateSettings{..} var stateref cntref = do
    cnt <- readIORef cntref
    act <- atomicModifyIORef' stateref $ change cnt
    switch act
  where
    change cnt Manual
      | cnt < updateSpawnThreshold = (Manual, Exec)
      | otherwise                  = (Spawning, Spawn)
    change _   Spawning            = (Spawning, Wait)
    change _   Auto                = (Auto, Return)

    switch Exec = do
        atomicModifyIORef' cntref $ \i -> (i + 1, ())
        updateAction
    switch Spawn = do
        new <- updateAction
        atomically $ putTMVar var new
        writeIORef stateref Auto
        writeIORef cntref 0
        void . forkIO $ spawn settings var stateref cntref
        return new
    switch Wait = atomically $ readTMVar var
    switch Return = do
        atomicModifyIORef' cntref $ \i -> (i + 1, ())
        atomically $ readTMVar var

spawn :: UpdateSettings a
      -> TMVar a
      -> IORef Status
      -> IORef Int
      -> IO ()
spawn UpdateSettings{..} var stateref cntref = loop `finally` cleanup
  where
    loop = do
        threadDelay updateFreq
        cnt <- readIORef cntref
        again <- atomicModifyIORef' stateref $ change cnt
        when again loop

    change cnt Auto | cnt >= 1 = (Auto, True)
    change _ _                 = (Manual, False)

    cleanup = do
        void . atomically $ tryTakeTMVar var
        writeIORef stateref Manual
        writeIORef cntref 0
