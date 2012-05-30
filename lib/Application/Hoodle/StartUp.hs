{-# LANGUAGE RecordWildCards #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Application.Hoodle.StartUp
-- Copyright   : (c) 2012 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module Application.Hoodle.StartUp where 

import System.Console.CmdArgs
import Application.Hoodle.ProgType
import Application.Hoodle.Command

import Control.Monad
import Control.Concurrent

import qualified Config.Dyre as Dyre 
import Config.Dyre.Relaunch

import System.FilePath
import System.Environment

import Application.Hoodle.Script

-- | 

hoodleMain ScriptConfig {..} = do 
    case errorMsg of 
      Nothing -> return () 
      Just em -> putStrLn $ "Error: " ++ em 
    -- 
    maybe (return ()) putStrLn message   
    -- 
    param <- cmdArgs mode
    commandLineProcess param hook

-- | 
    
hoodleStartMain = Dyre.wrapMain $ Dyre.defaultParams 
  { Dyre.projectName = "start"
  , Dyre.configDir = Just dirHoodled
  , Dyre.realMain = hoodleMain 
  , Dyre.showError = showError 
  , Dyre.hidePackages = ["meta-hoodle"] 
  } 

-- | 

dirHoodled :: IO FilePath 
dirHoodled = do
  homedir <- getEnv "HOME"
  return (homedir </> ".hoodle.d")


{-
-- | main starting point of the whole program

startUp :: IO () 
startUp = do 
    -- putStrLn "welcome to hoodle"
    -- param <- cmdArgs mode
    -- commandLineProcess param 
    hoodleStartMain defaultScriptConfig  
-}