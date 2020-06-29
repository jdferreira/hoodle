{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Hoodle.ModelAction.ContextMenu
-- Copyright   : (c) 2011-2015 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module Hoodle.ModelAction.ContextMenu where

import qualified Data.ByteString.Char8 as B
import           Data.UUID.V4
import qualified Graphics.Rendering.Cairo as Cairo
import qualified Graphics.UI.Gtk as Gtk
import           System.Directory 
import           System.FilePath 
#ifdef HUB
import           Control.Concurrent (forkIO, threadDelay)
import           Control.Exception
import           Data.Foldable (forM_)
import           DBus 
import           DBus.Client 
import           System.Process
#endif
-- 
import           Data.Hoodle.BBox
import           Data.Hoodle.Simple
import           Graphics.Hoodle.Render 
import           Graphics.Hoodle.Render.Type
--
import Hoodle.Type.Event 
import Hoodle.Util

-- |
menuOpenALink :: (AllEvent -> IO ()) -> UrlPath -> IO Gtk.MenuItem
menuOpenALink evhandler urlpath = do 
    let urlname = case urlpath of 
                    FileUrl fp -> fp 
                    HttpUrl url -> url 
    menuitemlnk <- Gtk.menuItemNewWithLabel ("Open "++urlname :: String) 
    menuitemlnk `Gtk.on` Gtk.menuItemActivate $ evhandler (UsrEv (OpenLink urlpath Nothing)) 
    return menuitemlnk

-- | 
#ifdef HUB
openLinkActionDBus :: UrlPath 
               -> Maybe (B.ByteString,B.ByteString) -- ^ (docid,anchorid)
               -> IO () 
openLinkActionDBus urlpath mid = do
    flip catch (\(ex :: SomeException) -> print ex ) $ do
      cli <- connectSession
      case urlpath of 
        FileUrl fp -> do 
          emit cli (signal "/" "org.ianwookim.hoodle" "findWindow") { signalBody = [ toVariant fp] }         
          return () 
        HttpUrl url -> do 
          let cmdargs = [url]
          createProcess (proc "xdg-open" cmdargs)  
          return () 
      forkIO $ do 
        threadDelay 2000000
        forM_ mid $ \(docid,anchorid) -> do
                    print (docid,anchorid)
                    emit cli (signal "/" "org.ianwookim.hoodle" "callLink")
                               { signalBody = 
                                   [ toVariant (B.unpack docid 
                                                ++ "," 
                                                ++ B.unpack anchorid) ] }
      return ()
#endif


-- | 
menuCreateALink :: (AllEvent -> IO ()) -> [RItem] -> IO (Maybe Gtk.MenuItem)
menuCreateALink evhandler sitems = 
  if (length . filter isLinkInRItem) sitems > 0
  then return Nothing 
  else do mi <- Gtk.menuItemNewWithLabel ("Create a link to..." :: String)
          mi `Gtk.on` Gtk.menuItemActivate $ 
            evhandler (UsrEv (GotContextMenuSignal CMenuCreateALink))
          return (Just mi)
         

-- |
makeSVGFromSelection :: RenderCache -> CanvasId -> [RItem] -> BBox -> IO SVG 
makeSVGFromSelection cache cid hititms (BBox (ulx,uly) (lrx,lry)) = do 
  uuid <- nextRandom
  tdir <- getTemporaryDirectory
  let filename = tdir </> show uuid <.> "svg"
      (x,y) = (ulx,uly)
      (w,h) = (lrx-ulx,lry-uly)
  Cairo.withSVGSurface filename w h $ \s -> Cairo.renderWith s $ do 
    Cairo.translate (-ulx) (-uly) 
    mapM_ (renderRItem cache cid) hititms 
  bstr <- B.readFile filename
  let svg = SVG Nothing Nothing bstr (x,y) (Dim w h)
  svg `seq` removeFile filename 
  return svg                       

