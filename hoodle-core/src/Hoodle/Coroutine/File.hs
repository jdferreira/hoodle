{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Hoodle.Coroutine.File 
-- Copyright   : (c) 2011-2014 Ian-Woo Kim
--
-- License     : GPL-3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module Hoodle.Coroutine.File where

-- from other packages
import           Control.Applicative ((<$>),(<*>))
import           Control.Concurrent
import           Control.Lens (view,set,over,(%~), (.~))
import           Control.Monad.State hiding (mapM,mapM_,forM_)
import           Control.Monad.Trans.Either
import           Control.Monad.Trans.Maybe (MaybeT(..))
-- import           Control.Monad.Trans.Reader (runReaderT)
import           Data.Attoparsec (parseOnly)
import           Data.ByteString.Char8 as B (pack,unpack,readFile)
import qualified Data.ByteString.Lazy as L
import           Data.Digest.Pure.MD5 (md5)
import           Data.Foldable (mapM_,forM_)
import qualified Data.List as List 
import           Data.Maybe
import qualified Data.IntMap as IM
import           Data.Time.Clock
import           Filesystem.Path.CurrentOS (decodeString, encodeString)
import qualified Graphics.Rendering.Cairo as Cairo
import qualified Graphics.UI.Gtk as Gtk -- hiding (get,set)
import           System.Directory
import           System.FilePath
import qualified System.FSNotify as FS
import           System.IO (hClose, hFileSize, openFile, IOMode(..))
import           System.Process 
-- from hoodle-platform
import           Control.Monad.Trans.Crtn
import           Control.Monad.Trans.Crtn.Queue 
-- import           Data.Hoodle.BBox
import           Data.Hoodle.Generic
import           Data.Hoodle.Simple
import           Data.Hoodle.Select
import           Graphics.Hoodle.Render 
                   (Xform4Page(..),cnstrctRHoodle, initRenderContext, renderPage, renderPage_StateT)
import           Graphics.Hoodle.Render.Generic
import           Graphics.Hoodle.Render.Item
import           Graphics.Hoodle.Render.Type
import           Graphics.Hoodle.Render.Type.HitTest 
import           Text.Hoodle.Builder 
import           Text.Hoodle.Migrate.FromXournal
import qualified Text.Hoodlet.Parse.Attoparsec as Hoodlet
import qualified Text.Xournal.Parse.Conduit as XP
-- from this package 
import           Hoodle.Accessor
import           Hoodle.Coroutine.Dialog
import           Hoodle.Coroutine.Draw
import           Hoodle.Coroutine.Commit
import           Hoodle.Coroutine.Minibuffer
import           Hoodle.Coroutine.Mode 
import           Hoodle.Coroutine.Page
import           Hoodle.Coroutine.Scroll
import           Hoodle.Coroutine.TextInput
import           Hoodle.ModelAction.File
import           Hoodle.ModelAction.Layer 
import           Hoodle.ModelAction.Page
import           Hoodle.ModelAction.Select
import           Hoodle.ModelAction.Window
import qualified Hoodle.Script.Coroutine as S
import           Hoodle.Script.Hook
import           Hoodle.Type.Canvas
import           Hoodle.Type.Coroutine
import           Hoodle.Type.Event hiding (TypSVG)
import           Hoodle.Type.HoodleState
import           Hoodle.Type.PageArrangement
import           Hoodle.Util
--
import Prelude hiding (readFile,concat,mapM,mapM_)

-- | 
askIfSave :: MainCoroutine () -> MainCoroutine () 
askIfSave action = do 
    xstate <- get 
    if not (view isSaved xstate)
      then do  
        b <- okCancelMessageBox "Current canvas is not saved yet. Will you proceed without save?" 
        case b of 
          True -> action 
          False -> return () 
      else action 

-- | 
askIfOverwrite :: FilePath -> MainCoroutine () -> MainCoroutine () 
askIfOverwrite fp action = do 
    b <- liftIO $ doesFileExist fp 
    if b 
      then do 
        r <- okCancelMessageBox ("Overwrite " ++ fp ++ "???") 
        if r then action else return () 
      else action 


-- | get file content from xournal file and update xournal state 
getFileContent :: Maybe FilePath -> MainCoroutine ()
getFileContent (Just fname) = do 
    xstate <- get
    let ext = takeExtension fname
    case ext of 
      ".hdl" -> do 
        bstr <- liftIO $ B.readFile fname
        r <- liftIO $ checkVersionAndMigrate bstr 
        case r of 
          Left err -> liftIO $ putStrLn err
          Right h -> do 
            constructNewHoodleStateFromHoodle h
            ctime <- liftIO $ getCurrentTime
            modify ( hoodleFileControl.hoodleFileName .~ Just fname )
            modify ( hoodleFileControl.lastSavedTime  .~ Just ctime )
            commit_
      ".xoj" -> do 
          liftIO (XP.parseXojFile fname) >>= \x -> case x of  
            Left str -> liftIO $ putStrLn $ "file reading error : " ++ str 
            Right xojcontent -> do 
              hdlcontent <- liftIO $ mkHoodleFromXournal xojcontent 
              constructNewHoodleStateFromHoodle hdlcontent
              ctime <- liftIO $ getCurrentTime 
              modify ( hoodleFileControl.hoodleFileName .~ Just fname )
              modify ( hoodleFileControl.lastSavedTime  .~ Just ctime ) 
              commit_
      ".pdf" -> do 
        let doesembed = view (settings.doesEmbedPDF) xstate
        mhdl <- liftIO $ makeNewHoodleWithPDF doesembed fname 
        case mhdl of 
          Nothing -> getFileContent Nothing
          Just hdl -> do 
            constructNewHoodleStateFromHoodle hdl
            modify ( hoodleFileControl.hoodleFileName .~ Nothing)
            commit_
      _ -> getFileContent Nothing    
    xstate' <- get
    doIOaction $ \evhandler -> do 
      Gtk.postGUIAsync (setTitleFromFileName xstate')
      return (UsrEv ActionOrdered)
    ActionOrdered <- waitSomeEvent (\case ActionOrdered -> True ; _ -> False )
    return ()
getFileContent Nothing = do
    constructNewHoodleStateFromHoodle =<< liftIO defaultHoodle 
    modify ( hoodleFileControl.hoodleFileName .~ Nothing ) 
    commit_ 


-- |
constructNewHoodleStateFromHoodle :: Hoodle -> MainCoroutine ()  
constructNewHoodleStateFromHoodle hdl' = do 
    callRenderer $ cnstrctRHoodle hdl' >>= return . GotRHoodle
    RenderEv (GotRHoodle rhdl) <- waitSomeEvent (\case RenderEv (GotRHoodle _) -> True; _ -> False)
    modify (hoodleModeState .~ ViewAppendState rhdl)


-- | 
fileNew :: MainCoroutine () 
fileNew = do  
    getFileContent Nothing
    xstate' <- get 
    ncvsinfo <- liftIO $ setPage xstate' 0 (getCurrentCanvasId xstate')
    xstate'' <- return $ over currentCanvasInfo (const ncvsinfo) xstate'
    liftIO $ setTitleFromFileName xstate''
    commit xstate'' 
    invalidateAll 

-- | 
fileSave :: MainCoroutine ()
fileSave = do 
    xstate <- get 
    case view (hoodleFileControl.hoodleFileName) xstate of
      Nothing -> fileSaveAs 
      Just filename -> do     
        -- this is rather temporary not to make mistake 
        if takeExtension filename == ".hdl" 
          then do 
             put =<< (liftIO (saveHoodle xstate))
             (S.afterSaveHook filename . rHoodle2Hoodle . getHoodle) xstate
          else fileExtensionInvalid (".hdl","save") >> fileSaveAs 

-- | interleaving a monadic action between each pair of subsequent actions
sequence1_ :: (Monad m) => m () -> [m ()] -> m () 
sequence1_ _ []  = return () 
sequence1_ _ [a] = a 
sequence1_ i (a:as) = a >> i >> sequence1_ i as 

{- 
-- | 
renderjob :: RenderCache -> RHoodle -> FilePath -> IO () 
renderjob cache h ofp = do 
  let p = maybe (error "renderjob") id $ IM.lookup 0 (view gpages h)  
  let Dim width height = view gdimension p  
  let rf x = cairoRenderOption (RBkgDrawPDF,DrawFull) cache (x,Nothing :: Maybe Xform4Page) >> return () 
  Cairo.withPDFSurface ofp width height $ \s -> Cairo.renderWith s $  
    (sequence1_ Cairo.showPage . map rf . IM.elems . view gpages ) h 
-}

-- | 
renderjob :: Hoodle -> FilePath -> IO () 
renderjob h ofp = do 
    let p = head (view pages h)
    let Dim width height = view dimension p  
    let rf x = renderPage x >> return ()
    ctxt <- initRenderContext h
    Cairo.withPDFSurface ofp width height $ \s -> 
      Cairo.renderWith s . flip runStateT ctxt $
        sequence1_ (lift Cairo.showPage) . map renderPage_StateT . view pages $ h 
    return ()
    --    (sequence1_ showPage . map rf . view S.pages ) h 

-- | 
fileExport :: MainCoroutine ()
fileExport = fileChooser Gtk.FileChooserActionSave Nothing >>= maybe (return ()) action 
  where 
    action filename = do
      liftIO $ putStrLn " IN FILE EXPORT "
      -- this is rather temporary not to make mistake 
      if takeExtension filename /= ".pdf" 
        then fileExtensionInvalid (".pdf","export") >> fileExport 
        else do      
          hdl <- rHoodle2Hoodle . getHoodle <$> get
          liftIO (renderjob hdl filename) 

-- | 
fileStartSync :: MainCoroutine ()
fileStartSync = do 
  xst <- get 
  let mf = (,) <$> view (hoodleFileControl.hoodleFileName) xst <*> view (hoodleFileControl.lastSavedTime) xst 
  maybe (return ()) (\(filename,lasttime) -> action filename lasttime) mf  
  where  
    action filename _lasttime  = do 
      let ioact = mkIOaction $ \evhandler ->do 
            forkIO $ do 
              FS.withManager $ \wm -> do 
                origfile <- canonicalizePath filename 
                let (filedir,_) = splitFileName origfile
                print filedir 
                _ <- FS.watchDir wm (decodeString filedir) (const True) $ \ev -> do
                  let mchangedfile = case ev of 
                        FS.Added fp _ -> Just (encodeString fp)
                        FS.Modified fp _ -> Just (encodeString fp)
                        FS.Removed _fp _ -> Nothing 
                  print mchangedfile 
                  case mchangedfile of 
                    Nothing -> return ()
                    Just changedfile -> do                       
                      let changedfilename = takeFileName changedfile 
                          changedfile' = (filedir </> changedfilename)
                      if changedfile' == origfile 
                        then do 
                          ctime <- getCurrentTime 
                          evhandler (UsrEv (Sync ctime))
                        else return () 

                let sec = 1000000
                forever (threadDelay (100 * sec))
            return (UsrEv ActionOrdered)
      modify (tempQueue %~ enqueue ioact) 

-- | need to be merged with ContextMenuEventSVG
exportCurrentPageAsSVG :: MainCoroutine ()
exportCurrentPageAsSVG = fileChooser Gtk.FileChooserActionSave Nothing >>= maybe (return ()) action 
  where 
    action filename = 
      -- this is rather temporary not to make mistake 
      if takeExtension filename /= ".svg" 
      then fileExtensionInvalid (".svg","export") >> exportCurrentPageAsSVG 
      else do
        cache <- view renderCache <$> get
        cpg <- getCurrentPageCurr
        let Dim w h = view gdimension cpg 
        liftIO $ Cairo.withSVGSurface filename w h $ \s -> Cairo.renderWith s $ 
         cairoRenderOption (InBBoxOption Nothing) cache (InBBox cpg,Nothing :: Maybe Xform4Page) >> return ()

-- | 
fileLoad :: FilePath -> MainCoroutine () 
fileLoad filename = do
    getFileContent (Just filename)
    xstate <- get 
    ncvsinfo <- liftIO $ setPage xstate 0 (getCurrentCanvasId xstate)
    xstateNew <- return $ over currentCanvasInfo (const ncvsinfo) xstate
    put . set isSaved True $ xstateNew 
    let ui = view gtkUIManager xstateNew
    liftIO $ toggleSave ui False
    liftIO $ setTitleFromFileName xstateNew  
    clearUndoHistory 
    modeChange ToViewAppendMode 
    resetHoodleBuffers 
    invalidateAll 
    applyActionToAllCVS adjustScrollbarWithGeometryCvsId

-- | 
resetHoodleBuffers :: MainCoroutine () 
resetHoodleBuffers = do 
    liftIO $ putStrLn "resetHoodleBuffers called"
    xst <- get 
    nhdlst <- liftIO $ resetHoodleModeStateBuffers  
                         (view renderCache xst)
                         (view hoodleModeState xst)
    let nxst = set hoodleModeState nhdlst xst
    put nxst     

-- | main coroutine for open a file 
fileOpen :: MainCoroutine ()
fileOpen = do 
    mfilename <- fileChooser Gtk.FileChooserActionOpen Nothing
    forM_ mfilename fileLoad 

-- | main coroutine for save as 
fileSaveAs :: MainCoroutine () 
fileSaveAs = do 
    xstate <- get 
    let hdl = (rHoodle2Hoodle . getHoodle) xstate
    maybe (defSaveAsAction xstate hdl) (\f -> liftIO (f hdl))
          (hookSaveAsAction xstate) 
  where 
    hookSaveAsAction xstate = do 
      hset <- view hookSet xstate
      saveAsHook hset
    defSaveAsAction xstate hdl = do 
        let msuggestedact = view hookSet xstate >>= fileNameSuggestionHook 
        (msuggested :: Maybe String) <- maybe (return Nothing) (liftM Just . liftIO) msuggestedact 
        mr <- fileChooser Gtk.FileChooserActionSave msuggested 
        maybe (return ()) (action xstate hdl) mr 
      where action xst' hd filename = 
              if takeExtension filename /= ".hdl" 
              then fileExtensionInvalid (".hdl","save")
              else do 
                askIfOverwrite filename $ do 
                  let ntitle = B.pack . snd . splitFileName $ filename 
                      (hdlmodst',hdl') = case view hoodleModeState xst' of
                         ViewAppendState hdlmap -> 
                           if view gtitle hdlmap == "untitled"
                             then ( ViewAppendState . set gtitle ntitle
                                    $ hdlmap
                                  , (set title ntitle hd))
                             else (ViewAppendState hdlmap,hd)
                         SelectState thdl -> 
                           if view gselTitle thdl == "untitled"
                             then ( SelectState $ set gselTitle ntitle thdl 
                                  , set title ntitle hd)  
                             else (SelectState thdl,hd)
                      xstateNew = set (hoodleFileControl.hoodleFileName) (Just filename) 
                                . set hoodleModeState hdlmodst' $ xst'
                  liftIO . L.writeFile filename . builder $ hdl'
                  put . set isSaved True $ xstateNew    
                  let ui = view gtkUIManager xstateNew
                  liftIO $ toggleSave ui False
                  liftIO $ setTitleFromFileName xstateNew 
                  S.afterSaveHook filename hdl'
          

-- | main coroutine for open a file 
fileReload :: MainCoroutine ()
fileReload = do 
    xstate <- get
    case view (hoodleFileControl.hoodleFileName) xstate of 
      Nothing -> return () 
      Just filename -> do
        if not (view isSaved xstate) 
          then do
            b <- okCancelMessageBox "Discard changes and reload the file?" 
            case b of 
              True -> fileLoad filename 
              False -> return ()
          else fileLoad filename

-- | 
fileExtensionInvalid :: (String,String) -> MainCoroutine ()
fileExtensionInvalid (ext,a) = 
  okMessageBox $ "only " 
                 ++ ext 
                 ++ " extension is supported for " 
                 ++ a 
    
-- | 
fileAnnotatePDF :: MainCoroutine ()
fileAnnotatePDF = 
    fileChooser Gtk.FileChooserActionOpen Nothing >>= maybe (return ()) action 
  where 
    warning = do 
      okMessageBox "cannot load the pdf file. Check your hoodle compiled with poppler library" 
      invalidateAll 
    action filename = do  
      xstate <- get 
      let doesembed = view (settings.doesEmbedPDF) xstate
      mhdl <- liftIO $ makeNewHoodleWithPDF doesembed filename 
      flip (maybe warning) mhdl $ \hdl -> do 
        constructNewHoodleStateFromHoodle hdl
        modify ( hoodleFileControl.hoodleFileName .~ Nothing)
        commit_        
        setTitleFromFileName_ 
        canvasZoomUpdateAll
        -- invalidateAll  
      

-- | set frame title according to file name
setTitleFromFileName_ :: MainCoroutine () 
setTitleFromFileName_ = get >>= liftIO . setTitleFromFileName



-- |
checkEmbedImageSize :: FilePath -> MainCoroutine (Maybe FilePath) 
checkEmbedImageSize filename = do 
  xst <- get 
  runMaybeT $ do 
    sizelimit <- (MaybeT . return) (warningEmbedImageSize =<< view hookSet xst)
    siz <- liftIO $ do  
      h <- openFile filename ReadMode 
      s <- hFileSize h 
      hClose h
      return s 
    guard (siz > sizelimit) 
    let suggestscale :: Double = sqrt (fromIntegral sizelimit / fromIntegral siz) 
    b <- lift . okCancelMessageBox $ "The size of " ++ filename ++ "=" ++ show siz ++ "\nis bigger than limit=" ++ show sizelimit ++ ".\nWill you reduce size?"
    guard b 
    let ext = let x' = takeExtension filename 
              in if (not.null) x' then tail x' else "" 
    tmpfile <- liftIO $ mkTmpFile ext 
    cmd <- (MaybeT . return) (shrinkCmd4EmbedImage =<< view hookSet xst)    
    liftIO $ cmd suggestscale filename tmpfile
    return tmpfile 

-- | 
fileLoadPNGorJPG :: MainCoroutine ()
fileLoadPNGorJPG = do 
    fileChooser Gtk.FileChooserActionOpen Nothing >>= maybe (return ()) embedImage

embedImage :: FilePath -> MainCoroutine ()
embedImage filename = do  
    xst <- get 
    nitm <- 
      if view (settings.doesEmbedImage) xst
        then do  
          mf <- checkEmbedImageSize filename 
          --
          callRenderer $ case mf of  
              Nothing -> liftIO (makeNewItemImage True filename) >>= cnstrctRItem >>= return . GotRItem 
              Just f -> liftIO (makeNewItemImage True f) >>= cnstrctRItem >>= return . GotRItem
          RenderEv (GotRItem r) <- waitSomeEvent (\case RenderEv (GotRItem _) -> True ; _ -> False )
          return r
        else do 
          callRenderer $ liftIO (makeNewItemImage False filename) >>= cnstrctRItem >>= return . GotRItem
          RenderEv (GotRItem r) <- waitSomeEvent (\case RenderEv (GotRItem _) -> True ; _ -> False )
          return r

    let cpn = view (currentCanvasInfo . unboxLens currentPageNum) xst
    my <- autoPosText 
    let mpos = (\y->(PageNum cpn,PageCoord (50,y)))<$>my  
    insertItemAt mpos nitm 

                    
-- | 
fileLoadSVG :: MainCoroutine ()
fileLoadSVG = do 
    fileChooser Gtk.FileChooserActionOpen Nothing >>= maybe (return ()) action 
  where 
    action filename = do 
      xstate <- get 
      liftIO $ putStrLn filename 
      bstr <- liftIO $ B.readFile filename 
      let pgnum = view (currentCanvasInfo . unboxLens currentPageNum) xstate
          hdl = getHoodle xstate 
          currpage = getPageFromGHoodleMap pgnum hdl
          currlayer = getCurrentLayer currpage
      --
      callRenderer $ return . GotRItem =<< (cnstrctRItem . ItemSVG) 
                       (SVG Nothing Nothing bstr (100,100) (Dim 300 300))
      RenderEv (GotRItem newitem) <- waitSomeEvent (\case RenderEv (GotRItem _) -> True ; _ -> False )
      -- 
      let otheritems = view gitems currlayer  
      let ntpg = makePageSelectMode currpage (otheritems :- (Hitted [newitem]) :- Empty)  
      modeChange ToSelectMode 
      nxstate <- get 
      let cache = view renderCache nxstate
      thdl <- case view hoodleModeState nxstate of
                SelectState thdl' -> return thdl'
                _ -> (lift . EitherT . return . Left . Other) "fileLoadSVG"
      nthdl <- liftIO $ updateTempHoodleSelectIO cache thdl ntpg pgnum 
      put ( ( set hoodleModeState (SelectState nthdl) 
            . set isOneTimeSelectMode YesAfterSelect) nxstate)
      invalidateAll 

-- |
askQuitProgram :: MainCoroutine () 
askQuitProgram = do 
    b <- okCancelMessageBox "Current canvas is not saved yet. Will you close hoodle?" 
    case b of 
      True -> doIOaction $ \evhander -> Gtk.postGUIAsync Gtk.mainQuit >> return (UsrEv ActionOrdered)
      False -> return ()
  
-- | 
embedPredefinedImage :: MainCoroutine () 
embedPredefinedImage = do 
    mpredefined <- S.embedPredefinedImageHook 
    case mpredefined of 
      Nothing -> return () 
      Just filename -> embedImage filename
          
-- | this is temporary. I will remove it
embedPredefinedImage2 :: MainCoroutine () 
embedPredefinedImage2 = do 
    mpredefined <- S.embedPredefinedImage2Hook 
    case mpredefined of 
      Nothing -> return () 
      Just filename -> embedImage filename 
        
-- | this is temporary. I will remove it
embedPredefinedImage3 :: MainCoroutine () 
embedPredefinedImage3 = do 
    mpredefined <- S.embedPredefinedImage3Hook 
    case mpredefined of 
      Nothing -> return () 
      Just filename -> embedImage filename 
        
-- | 
embedAllPDFBackground :: MainCoroutine () 
embedAllPDFBackground = do 
  xst <- get 
  let hdl = (rHoodle2Hoodle  . getHoodle) xst
  nhdl <- liftIO . embedPDFInHoodle $ hdl
  constructNewHoodleStateFromHoodle nhdl
  commit_
  invalidateAll   
  
-- | embed an item from hoodlet using hoodlet identifier
embedHoodlet :: String -> MainCoroutine ()
embedHoodlet str = loadHoodlet str >>= mapM_ (insertItemAt Nothing) 

-- |
mkRevisionHdlFile :: Hoodle -> IO (String,String)
mkRevisionHdlFile hdl = do 
    hdir <- getHomeDirectory
    tempfile <- mkTmpFile "hdl"
    let hdlbstr = builder hdl 
    L.writeFile tempfile hdlbstr
    ctime <- getCurrentTime 
    let idstr = B.unpack (view hoodleID hdl)
        md5str = show (md5 hdlbstr)
        name = "UUID_"++idstr++"_MD5Digest_"++md5str++"_ModTime_"++ show ctime
        nfilename = name <.> "hdl"
        vcsdir = hdir </> ".hoodle.d" </> "vcs"
    b <- doesDirectoryExist vcsdir 
    unless b $ createDirectory vcsdir
    renameFile tempfile (vcsdir </> nfilename)  
    return (md5str,name) 


mkRevisionPdfFile :: {- RenderCache -> -} Hoodle -> String -> IO ()
mkRevisionPdfFile {- cache -} hdl fname = do 
    hdir <- getHomeDirectory
    tempfile <- mkTmpFile "pdf"
    renderjob {- cache -} hdl tempfile 
    let nfilename = fname <.> "pdf"
        vcsdir = hdir </> ".hoodle.d" </> "vcs"
    b <- doesDirectoryExist vcsdir 
    unless b $ createDirectory vcsdir
    renameFile tempfile (vcsdir </> nfilename)  

-- | 
fileVersionSave :: MainCoroutine () 
fileVersionSave = do 
    -- rhdl <- getHoodle <$> get 
    -- cache <- view renderCache <$> get
    hdl <- rHoodle2Hoodle . getHoodle <$> get
    rmini <- minibufDialog "Commit Message:"
    case rmini of 
      Right [] -> return ()
      Right strks' -> do
        doIOaction $ \_evhandler -> do 
          (md5str,fname) <- mkRevisionHdlFile hdl
          mkRevisionPdfFile hdl fname
          return (UsrEv (GotRevisionInk md5str strks'))
        r <- waitSomeEvent (\case GotRevisionInk _ _ -> True ; _ -> False )
        let GotRevisionInk md5str strks = r          
            nrev = RevisionInk (B.pack md5str) strks
        modify (\xst -> let hdlmodst = view hoodleModeState xst 
                        in case hdlmodst of 
                             ViewAppendState rhdl' -> 
                               let nrhdl = over grevisions (<> [nrev]) rhdl' 
                               in set hoodleModeState (ViewAppendState nrhdl) xst 
                             SelectState thdl -> 
                               let nthdl = over gselRevisions (<> [nrev]) thdl
                               in set hoodleModeState (SelectState nthdl) xst)
        commit_ 
      Left () -> do 
        txtstr <- maybe "" id <$> textInputDialog
        doIOaction $ \_evhandler -> do 
          (md5str,fname) <- mkRevisionHdlFile hdl
          mkRevisionPdfFile hdl fname
          return (UsrEv (GotRevision md5str txtstr))
        r <- waitSomeEvent (\case GotRevision _ _ -> True ; _ -> False )
        let GotRevision md5str txtstr' = r          
            nrev = Revision (B.pack md5str) (B.pack txtstr')
        modify (\xst -> let hdlmodst = view hoodleModeState xst 
                        in case hdlmodst of 
                             ViewAppendState rhdl' -> 
                               let nrhdl = over grevisions (<> [nrev]) rhdl' 
                               in set hoodleModeState (ViewAppendState nrhdl) xst 
                             SelectState thdl -> 
                               let nthdl = over gselRevisions (<> [nrev]) thdl
                               in set hoodleModeState (SelectState nthdl) xst)
        commit_ 



showRevisionDialog :: Hoodle -> [Revision] -> MainCoroutine ()
showRevisionDialog hdl revs = 
    liftM (view renderCache) get >>= \cache -> 
    modify (tempQueue %~ enqueue (action cache)) 
    >> waitSomeEvent (\case GotOk -> True ; _ -> False)
    >> return ()
  where 
    action cache 
       = mkIOaction $ \_evhandler -> do 
               dialog <- Gtk.dialogNew
               vbox <- Gtk.dialogGetUpper dialog
               mapM_ (addOneRevisionBox cache vbox hdl) revs 
               _btnOk <- Gtk.dialogAddButton dialog ("Ok" :: String) Gtk.ResponseOk
               Gtk.widgetShowAll dialog
               _res <- Gtk.dialogRun dialog
               Gtk.widgetDestroy dialog
               return (UsrEv GotOk)


mkPangoText :: String -> Cairo.Render ()
mkPangoText str = do 
    let pangordr = do 
          ctxt <- Gtk.cairoCreateContext Nothing 
          layout <- Gtk.layoutEmpty ctxt   
          fdesc <- Gtk.fontDescriptionNew 
          Gtk.fontDescriptionSetFamily fdesc ("Sans Mono" :: String)
          Gtk.fontDescriptionSetSize fdesc 8.0 
          Gtk.layoutSetFontDescription layout (Just fdesc)
          Gtk.layoutSetWidth layout (Just 250)
          Gtk.layoutSetWrap layout Gtk.WrapAnywhere 
          Gtk.layoutSetText layout str 
          return layout
        rdr layout = do Cairo.setSourceRGBA 0 0 0 1
                        Gtk.updateLayout layout 
                        Gtk.showLayout layout 
    layout <- liftIO $ pangordr 
    rdr layout

addOneRevisionBox :: RenderCache -> Gtk.VBox -> Hoodle -> Revision -> IO ()
addOneRevisionBox cache vbox hdl rev = do 
    cvs <- Gtk.drawingAreaNew 
    cvs `Gtk.on` Gtk.sizeRequest $ return (Gtk.Requisition 250 25)
    cvs `Gtk.on` Gtk.exposeEvent $ Gtk.tryEvent $ do 
      drawwdw <- liftIO $ Gtk.widgetGetDrawWindow cvs 
      liftIO . Gtk.renderWithDrawable drawwdw $ do 
        case rev of 
          RevisionInk _ strks -> Cairo.scale 0.5 0.5 >> mapM_ (cairoRender cache) strks
          Revision _ txt -> mkPangoText (B.unpack txt)            
    hdir <- getHomeDirectory
    let vcsdir = hdir </> ".hoodle.d" </> "vcs"
    btn <- Gtk.buttonNewWithLabel ("view" :: String)
    btn `Gtk.on` Gtk.buttonPressEvent $ Gtk.tryEvent $ do 
      files <- liftIO $ getDirectoryContents vcsdir 
      let fstrinit = "UUID_" ++ B.unpack (view hoodleID hdl)  
                      ++ "_MD5Digest_" ++ B.unpack (view revmd5 rev)
                 
          matched = filter ((== "fdp") . take 3 . reverse) 
                    . filter (\f -> fstrinit  `List.isPrefixOf` f) $ files
      case matched of 
        x : _ -> 
          liftIO (createProcess (proc "evince" [vcsdir </> x])) 
          >> return ()
        _ -> return ()    
    hbox <- Gtk.hBoxNew False 0
    Gtk.boxPackStart hbox cvs Gtk.PackNatural 0
    Gtk.boxPackStart hbox btn Gtk.PackGrow  0
    Gtk.boxPackStart vbox hbox Gtk.PackNatural 0

fileShowRevisions :: MainCoroutine ()
fileShowRevisions = do 
    rhdl <- liftM getHoodle get  
    let hdl = rHoodle2Hoodle rhdl
    let revs = view grevisions rhdl
    showRevisionDialog hdl revs 
  
fileShowUUID :: MainCoroutine ()
fileShowUUID = do 
    hdl <- liftM getHoodle get  
    let uuidstr = view ghoodleID hdl
    okMessageBox (B.unpack uuidstr)
  

loadHoodlet :: String -> MainCoroutine (Maybe RItem)
loadHoodlet str = do
     homedir <- liftIO getHomeDirectory
     let hoodled = homedir </> ".hoodle.d"
         hoodletdir = hoodled </> "hoodlet"
     b' <- liftIO $ doesDirectoryExist hoodletdir 
     if b' 
       then do            
         let fp = hoodletdir </> str <.> "hdlt"
         bstr <- liftIO $ B.readFile fp 
         case parseOnly Hoodlet.hoodlet bstr of 
           Left err -> liftIO $ putStrLn err >> return Nothing
           Right itm -> do
             --
             callRenderer $ cnstrctRItem itm >>= return . GotRItem 
             RenderEv (GotRItem ritm) <- 
               waitSomeEvent (\case RenderEv (GotRItem _) -> True; _ -> False )
             --
             return (Just ritm) 
       else return Nothing

  
  
  
