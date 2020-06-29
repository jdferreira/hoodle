{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Hoodle.Coroutine.Hub where

import Control.Applicative
import Control.Lens (view)
import Control.Monad.IO.Class
import Control.Monad.State
import Control.Monad.Trans.Maybe
--

import Hoodle.Coroutine.Dialog
import Hoodle.Coroutine.HubInternal
import Hoodle.Script.Hook
import Hoodle.Type.Coroutine
import Hoodle.Type.HoodleState
import Hoodle.Type.Hub
import System.Directory
import System.FilePath (makeRelative)

--

-- |
hubUpload :: MainCoroutine ()
hubUpload = do
  xst <- get
  uhdl <- view (unitHoodles . currentUnit) <$> get
  if not (view isSaved uhdl)
    then okMessageBox "hub action can be done only after saved" >> return ()
    else do
      r <- runMaybeT $ do
        hset <- (MaybeT . return) $ view hookSet xst
        hinfo <- (MaybeT . return) (hubInfo hset)
        let hdir = hubFileRoot hinfo
        (canfp, mhdlfp) <-
          case view (hoodleFileControl . hoodleFileName) uhdl of
            LocalDir Nothing -> MaybeT (return Nothing)
            LocalDir (Just fp) -> do
              canfp <- liftIO $ canonicalizePath fp
              let relfp = makeRelative hdir canfp
              MaybeT . return . Just $ (canfp, Just relfp)
            TempDir fp -> do
              canfp <- liftIO $ canonicalizePath fp
              MaybeT . return . Just $ (canfp, Nothing)
        lift (uploadWork (canfp, mhdlfp) hinfo)
      case r of
        Nothing -> okMessageBox "upload not successful" >> return ()
        Just _ -> return ()
