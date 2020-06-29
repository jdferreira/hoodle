{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Hoodle.Coroutine.HubInternal where

import           Control.Applicative
import           Control.Concurrent
import qualified Control.Exception as E
import           Control.Lens (over,view,set,_2)
import           Control.Monad.IO.Class
import           Control.Monad.State
import           Control.Monad.Trans.Maybe
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.Resource
import           Data.Aeson as AE
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as BL
import           Data.Digest.Pure.MD5 (md5)
import qualified Data.Foldable as F
import qualified Data.IntMap as IM
import           Data.List (find)
import qualified Data.Text as T (Text,pack,unpack)
import qualified Data.Text.Encoding as TE (encodeUtf8,decodeUtf8)
import           Data.UUID
import           Data.UUID.V4
import           Database.Persist (upsert, getBy)
import           Database.Persist.Sql (runMigration)
import           Database.Persist.Sqlite (runSqlite)
import qualified Graphics.UI.Gtk as Gtk
import           Network.HTTP.Conduit ( RequestBody(..), CookieJar, Manager
                                      , cookieJar, httpLbs, method, parseUrl
                                      , requestBody, responseBody)
import           Network.HTTP.Types (methodPut)
import           System.Directory
import           System.FilePath ((</>),(<.>),makeRelative)
import           System.Process (readProcessWithExitCode)
--
import           Data.Hoodle.Generic
import           Data.Hoodle.Simple
import           Graphics.Hoodle.Render.Type.Hoodle
import           Text.Hoodle.Builder (builder)
--
import           Hoodle.Accessor
import           Hoodle.Coroutine.Hub.Common
import           Hoodle.Script.Hook
import           Hoodle.Type.Coroutine
import           Hoodle.Type.Event
import           Hoodle.Type.Hub
import           Hoodle.Type.HoodleState
import           Hoodle.Type.Synchronization
--

         
uploadWork :: (FilePath,Maybe FilePath) -> HubInfo -> MainCoroutine ()
uploadWork (canfp,mhdlfp) hinfo@(HubInfo {..}) = do
    uhdl0 <- view (unitHoodles.currentUnit) <$> get
    let hdl = (rHoodle2Hoodle . getHoodle) uhdl0
        hdllbstr = builder hdl
        hdlbstr = BL.toStrict hdllbstr
        hdlmd5txt = T.pack (show (md5 hdllbstr))
    pureUpdateUhdl $ over (hoodleFileControl.syncMD5History) (hdlmd5txt:)
    uhdl <- view (unitHoodles.currentUnit) <$> get
    let synchist = view (hoodleFileControl.syncMD5History) uhdl
        uhdluuid = view unitUUID uhdl

    hdir <- liftIO $ getHomeDirectory
    msqlfile <- view (settings.sqliteFileName) <$> get
    let tokfile = hdir </> ".hoodle.d" </> "token.txt"
    prepareToken hinfo tokfile
    doIOaction $ \evhandler -> do 
      forkIO $ (`E.catch` (\(e :: E.SomeException)-> print e >> (Gtk.postGUIAsync . evhandler . UsrEv) (DisconnectedHub tokfile (canfp,mhdlfp) hinfo) >> return ())) $ 
        withHub hinfo tokfile $ \manager coojar -> do
          let uuidtxt = TE.decodeUtf8 (view hoodleID hdl)
          flip runReaderT (manager,coojar) $ do
            mfstat <- sessionGetJSON (hubURL </> "sync" </> T.unpack uuidtxt)
            let uploading = uploadAndUpdateSync evhandler uhdluuid hinfo uuidtxt hdlbstr (canfp,mhdlfp) msqlfile
            flip (maybe uploading) ((,) <$> msqlfile <*> mfstat) $ 
              \(sqlfile,fstat) -> do
                me <- runSqlite (T.pack sqlfile) $ getBy (UniqueFileSyncStatusUUID (fileSyncStatusUuid fstat))
                case me of 
                  Just _ -> do 
                    let remotemd5saved = fileSyncStatusMd5 fstat
                    if (remotemd5saved `elem` synchist ) || (Prelude.null synchist)
                      then uploading
                      else do 
                        liftIO $ putStrLn ("uploadWork" ++ show remotemd5saved ++ "," ++ show synchist)
                        liftIO $ evhandler (UsrEv (FileSyncFromHub uhdluuid fstat))
                  Nothing -> uploading
      return (UsrEv ActionOrdered)


uploadAndUpdateSync :: (AllEvent -> IO ()) -> UUID -> HubInfo -> T.Text -> B.ByteString  
                    -> (FilePath,Maybe FilePath) -> Maybe FilePath 
                    -> ReaderT (Manager,CookieJar) (ResourceT IO) ()
uploadAndUpdateSync evhandler uhdluuid hinfo uuidtxt hdlbstr (canfp,mhdlfp) msqlfile = do
    mfrsync <- sessionGetJSON (hubURL hinfo </> "file" </> T.unpack uuidtxt) 
    b64txt <- case mfrsync of 
      Nothing -> (return . TE.decodeUtf8 . B64.encode) hdlbstr
      Just frsync -> liftIO $ do
        let rsyncbstr = (B64.decodeLenient . TE.encodeUtf8 . frsync_sig) frsync
        tdir <- getTemporaryDirectory
        uuid'' <- nextRandom
        let tsigfile = tdir </> show uuid'' <.> "sig"
            tdeltafile = tdir </> show uuid'' <.> "delta"
        B.writeFile tsigfile rsyncbstr
        readProcessWithExitCode "rdiff" 
          ["delta", tsigfile, canfp, tdeltafile] ""
        deltabstr <- B.readFile tdeltafile 
        -- mapM_ removeFile [tsigfile,tdeltafile]
        (return . TE.decodeUtf8 . B64.encode) deltabstr
    let filecontent = toJSON FileContent { file_uuid = uuidtxt
                                         , file_path = T.pack <$> mhdlfp 
                                         , file_content = b64txt 
                                         , file_rsync = mfrsync 
                                         , client_uuid = T.pack (show uhdluuid)
                                         }
        filecontentbstr = encode filecontent
    (manager,coojar) <- ask
    request3' <- lift $ parseUrl (hubURL hinfo </> "file" </> T.unpack uuidtxt )
    let request3 = request3' { method = methodPut
                             , requestBody = RequestBodyStreamChunked (streamContent filecontentbstr)
                             , cookieJar = Just coojar }
    _response3 <- lift $ httpLbs request3 manager
    mfstat2 :: Maybe FileSyncStatus 
      <- sessionGetJSON (hubURL hinfo </> "sync" </> T.unpack uuidtxt)
    F.forM_ ((,) <$> msqlfile <*> mfstat2) $ \(sqlfile,fstat2) -> do 
      runSqlite (T.pack sqlfile) $ upsert fstat2 []
      liftIO $ evhandler (UsrEv (SyncInfoUpdated uhdluuid fstat2))
    return ()

-- | 
initSqliteDB :: MainCoroutine ()
initSqliteDB = do
    msqlfile <- view (settings.sqliteFileName) <$> get
    F.forM_ msqlfile $ \sqlfile -> liftIO $ do
      runSqlite (T.pack sqlfile) $ runMigration $ migrateAll

-- | 
updateSyncInfo :: UUID -> FileSyncStatus -> MainCoroutine ()
updateSyncInfo uuid fstat = do
    liftIO $ putStrLn "updateSyncInfo called"
    uhdlsMap <-  snd . view unitHoodles <$> get
    let uhdls = IM.elems uhdlsMap
    case find (\x -> view unitUUID x == uuid) uhdls of 
      Nothing -> do
        liftIO $ putStrLn ("uuid=" ++ show uuid)
        return ()
      Just uhdl -> do 
        liftIO $ putStrLn "HERE"
        let nuhdlsMap = IM.adjust (over (hoodleFileControl.syncMD5History) (fileSyncStatusMd5 fstat :) ) (view unitKey uhdl) uhdlsMap
        modify (set (unitHoodles._2) nuhdlsMap)


-- | 
updateSyncInfoAll :: FileSyncStatus -> MainCoroutine ()
updateSyncInfoAll fstat = do
    let fileuuid = fileSyncStatusUuid fstat    
    uhdlsMap <-  snd . view unitHoodles <$> get
    let f uhdl = let fileuuid' = getHoodleID uhdl
                 in if fileuuid == fileuuid' 
                    then over (hoodleFileControl.syncMD5History) (fileSyncStatusMd5 fstat :) uhdl
                    else uhdl
        nuhdlsMap = fmap f uhdlsMap
    modify (set (unitHoodles._2) nuhdlsMap)
    
-- |
fileSyncFromHub :: UUID -> FileSyncStatus -> MainCoroutine ()
fileSyncFromHub unituuid fstat = do
    liftIO $ putStrLn "fileSyncFromHub called"
    uhdlsMap <-  snd . view unitHoodles <$> get
    let uhdls = IM.elems uhdlsMap
    hdir <- liftIO $ getHomeDirectory
    let tokfile = hdir </> ".hoodle.d" </> "token.txt"
    xst <- get
    runMaybeT $ do
      uhdl <- (MaybeT . return . find (\x -> view unitUUID x == unituuid)) uhdls 
      hdlfp <- MaybeT . return $ getHoodleFilePath uhdl  
      hset <- (MaybeT . return . view hookSet) xst
      hinfo <- (MaybeT . return) (hubInfo hset)
      lift $ prepareToken hinfo tokfile
      lift $ doIOaction $ \evhandler -> do 
        forkIO $ (`E.catch` (\(e :: E.SomeException)-> print e >> return ())) $ 
          withHub hinfo tokfile $ \manager coojar -> do
            flip runReaderT (manager,coojar) $
              rsyncPatchWork hinfo hdlfp fstat $
                (evhandler . UsrEv) (SyncInfoUpdated unituuid fstat)
        return (UsrEv ActionOrdered)
    return ()

-- |
rsyncPatchWork :: HubInfo -> FilePath -> FileSyncStatus 
               -> IO ()
               -> ReaderT (Manager,CookieJar) (ResourceT IO) ()
rsyncPatchWork hinfo hdlfile fstat action = do 
    (manager,coojar) <- ask
    let uuidtxt = fileSyncStatusUuid fstat
    sigtxt <- liftIO $ do 
                uuid' <- nextRandom
                tdir <- getTemporaryDirectory
                let sigfile = tdir </> show uuid' <.> "sig"
                readProcessWithExitCode "rdiff" ["signature", hdlfile, sigfile] ""
                bstr <- B.readFile sigfile
                return (TE.decodeUtf8 (B64.encode bstr))
    let frsync = FileRsync uuidtxt sigtxt
        frsyncjsonbstr = (encode . toJSON) frsync
    req' <- lift $ parseUrl (hubURL hinfo </> "rsyncdown" </> T.unpack uuidtxt)
    let req = req' { cookieJar = Just coojar 
                   , requestBody = RequestBodyStreamChunked (streamContent frsyncjsonbstr)
                   }
    mfcont <- lift $ AE.decode . responseBody <$> httpLbs req manager
    F.forM_ mfcont $ \fcont -> do
      let filebstr = (B64.decodeLenient . TE.encodeUtf8 . file_content) fcont 
      liftIO $ do 
        uuid' <- nextRandom
        tdir <- getTemporaryDirectory 
        let deltafile = tdir </> show uuid' <.> "delta"
            newfile = tdir </> show uuid' <.> "hdlnew"
        B.writeFile deltafile filebstr
        readProcessWithExitCode "rdiff" ["patch", hdlfile, deltafile, newfile] ""
        md5str <- show . md5 <$> BL.readFile newfile 
        when (md5str == T.unpack (fileSyncStatusMd5 fstat)) $ do
          copyFile newfile hdlfile
          mapM_ removeFile [deltafile,newfile]
          Gtk.postGUIAsync action
        
-- |
gotSyncEvent :: Bool -> UUID -> FileSyncStatus -> MainCoroutine ()
gotSyncEvent isforced unituuid fstat = do
    liftIO $ putStrLn "gotSyncEvent called"
    uhdlsMap <-  snd . view unitHoodles <$> get
    let uhdls = IM.elems uhdlsMap
    let b = maybe True (const isforced) (find (\x -> view unitUUID x == unituuid) uhdls)
    when b $ fileSyncFromHub unituuid fstat

-- |
registerFile :: UUID -> (FilePath,Hoodle) -> MainCoroutine ()
registerFile uhdluuid (fp,hdl) = do 
    liftIO $ putStrLn "registerFile called"
    let hdlbstr = (BL.toStrict . builder) hdl
    hdir <- liftIO $ getHomeDirectory
    canfp <- liftIO $ canonicalizePath fp
    let mhdlfp = Just (makeRelative hdir canfp)
    xst <- get
    let fileuuidbstr = view hoodleID hdl
        fileuuidtxt = TE.decodeUtf8 fileuuidbstr
    let tokfile = hdir </> ".hoodle.d" </> "token.txt"
    runMaybeT $ do
      sqlfile <- (MaybeT . return . view (settings.sqliteFileName)) xst
      hset <- (MaybeT . return . view hookSet) xst
      hinfo <- (MaybeT . return) (hubInfo hset)
      lift $ prepareToken hinfo tokfile
      lift . doIOaction $ \evhandler -> do 
        forkIO $ (`E.catch` (\(e :: E.SomeException)-> print e)) $ 
          withHub hinfo tokfile $ \manager coojar -> do
            flip runReaderT (manager,coojar) $ do
              uploadAndUpdateSync evhandler uhdluuid hinfo fileuuidtxt hdlbstr (canfp,mhdlfp) (Just sqlfile)
              Just fstat <- sessionGetJSON (hubURL hinfo </> "sync" </> T.unpack fileuuidtxt)

              (liftIO . Gtk.postGUIAsync . evhandler . UsrEv) (SyncInfoUpdated uhdluuid fstat)
        return (UsrEv ActionOrdered)
    return ()    

-- |
findUnitHoodleByHoodleID :: String ->  MainCoroutine (Maybe UnitHoodle)
findUnitHoodleByHoodleID uuidstr = do 
    uhdlsMap <-  snd . view unitHoodles <$> get
    let uhdls = IM.elems uhdlsMap
        muhdl = find ((== uuidstr) . B.unpack . view ghoodleID . getHoodle) uhdls 
    return muhdl 




openShared :: UUID -> MainCoroutine ()
openShared uuid = do 
    xst <- get
    hdir <- liftIO $ getHomeDirectory
    let uuidstr = show uuid
    let tokfile = hdir </> ".hoodle.d" </> "token.txt"
    tmpfile <- liftIO $ (</> uuidstr <.> "hdl" ) <$> getTemporaryDirectory 
    liftIO $ writeFile tmpfile "" 
    runMaybeT $ do
      hset <- (MaybeT . return . view hookSet) xst
      hinfo <- (MaybeT . return) (hubInfo hset)
      lift $ prepareToken hinfo tokfile
      lift $ doIOaction $ \evhandler -> do 
        forkIO $ (`E.catch` (\(e :: E.SomeException)-> print e >> return ())) $ 
          withHub hinfo tokfile $ \manager coojar -> do
            flip runReaderT (manager,coojar) $ do
              mfstat <- sessionGetJSON (hubURL hinfo </> "sync" </> uuidstr)
              case mfstat of
                Nothing -> return ()
                Just fstat -> 
                  rsyncPatchWork hinfo tmpfile fstat $
                    (evhandler . UsrEv) (OpenTemp uuid tmpfile)
        return (UsrEv ActionOrdered)
    return ()


