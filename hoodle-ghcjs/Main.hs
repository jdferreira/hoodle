{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Concurrent.MVar (newEmptyMVar, putMVar)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.State (MonadState (get, put), modify')
import qualified Control.Monad.Trans.Crtn.Driver as D (driver)
import Control.Monad.Trans.Crtn.EventHandler (eventHandler)
import Control.Monad.Trans.Crtn.Object (Arg (..))
import Control.Monad.Trans.Reader (ReaderT (..))
import Coroutine
  ( EventVar,
    MainCoroutine,
    MainObj,
    MainOp (DoEvent),
    nextevent,
    putStrLnAndFlush,
    simplelogger,
    world,
  )
import Data.Foldable (toList)
import Data.Hashable (hash)
import qualified Data.JSString as JSS (pack, unpack)
import Data.List (nub, sort)
import Data.Sequence (Seq, ViewR (..), singleton, viewr, (|>))
import qualified Data.Text as T
import Event (AllEvent (..))
import qualified ForeignJS as J
import GHCJS.Foreign.Callback
  ( Callback,
    OnBlocked (ThrowWouldBlock),
    syncCallback,
    syncCallback1,
  )
import GHCJS.Marshal (FromJSVal (..), ToJSVal (..))
import GHCJS.Types (JSString, JSVal, jsval)
import HitTest (do2LinesIntersect, doesLineHitStrk)
import qualified JavaScript.Web.MessageEvent as ME
import qualified JavaScript.Web.WebSocket as WS
import Message
  ( C2SMsg (NewStroke, SyncRequest),
    S2CMsg (DataStrokes, RegisterStroke),
    TextSerializable (deserialize, serialize),
  )
import State (DocState (..), HoodleState (..), SyncState (..))

data PointerType = Mouse | Touch | Pen
  deriving (Show, Eq)

getPointerType :: JSVal -> IO PointerType
getPointerType ev = J.js_pointer_type ev >>= \s -> do
  case JSS.unpack s of
    "touch" -> pure Touch
    "pen" -> pure Pen
    _ -> pure Mouse

getXY :: JSVal -> IO (Double, Double)
getXY ev = (,) <$> J.js_clientX ev <*> J.js_clientY ev

drawPath :: JSVal -> [(Double, Double)] -> IO ()
drawPath svg xys = do
  arr <- toJSValListOf xys
  J.js_draw_path svg arr

onPointerDown ::
  EventVar ->
  JSVal ->
  IO ()
onPointerDown evar ev = do
  v <- J.js_pointer_type ev
  J.js_debug_show (jsval v)
  t <- getPointerType ev
  when (t /= Touch) $ do
    (x, y) <- getXY ev
    eventHandler evar $ PointerDown (x, y)

onPointerUp ::
  EventVar ->
  JSVal ->
  IO ()
onPointerUp evar ev = do
  J.js_debug_show $ jsval ("ready for input" :: JSString)
  t <- getPointerType ev
  when (t /= Touch) $ do
    (x, y) <- getXY ev
    eventHandler evar (PointerUp (x, y))

onPointerMove ::
  EventVar ->
  JSVal ->
  IO ()
onPointerMove evar ev = do
  t <- getPointerType ev
  when (t /= Touch) $ do
    (x, y) <- getXY ev
    eventHandler evar (PointerMove (x, y))

test :: JSVal -> JSVal -> Callback (IO ()) -> IO ()
test cvs offcvs rAF = do
  J.js_refresh cvs offcvs
  J.js_requestAnimationFrame rAF

onMessage :: EventVar -> JSString -> IO ()
onMessage evar s = do
  case deserialize $ T.pack $ JSS.unpack s of
    RegisterStroke (s', hsh') -> do
      eventHandler evar (ERegisterStroke (s', hsh'))
    DataStrokes dat -> do
      eventHandler evar (EDataStrokes dat)

data Mode = ModePen | ModeEraser
  deriving (Show)

onModeChange :: Mode -> EventVar -> JSVal -> IO ()
onModeChange m evar _ = do
  case m of
    ModePen -> eventHandler evar ToPenMode
    ModeEraser -> eventHandler evar ToEraserMode

guiProcess :: AllEvent -> MainCoroutine ()
guiProcess = penReady

penReady :: AllEvent -> MainCoroutine ()
penReady ev = do
  case ev of
    ERegisterStroke (s', hsh') -> do
      HoodleState _ _ _ sock (DocState n _) _ <- get
      liftIO $ putStrLnAndFlush (show s' ++ " <-> " ++ show n)
      liftIO $ putStrLnAndFlush (show hsh')
      when (s' > n) $ liftIO $ do
        let msg = SyncRequest (n, s')
        WS.send (JSS.pack . T.unpack . serialize $ msg) sock
    EDataStrokes dat -> do
      st@(HoodleState svg _ offcvs _ (DocState _ dat0) _) <- get
      liftIO $ do
        J.js_clear_overlay offcvs
        mapM_ (drawPath svg . snd) dat
      let i = maximum (map fst dat)
      put $ st {_hdlstateDocState = DocState i (dat0 ++ dat)}
    PointerDown (x, y) ->
      drawingMode (singleton (x, y))
    ToPenMode -> pure ()
    ToEraserMode -> nextevent >>= eraserReady
    _ -> do
      liftIO $ putStrLnAndFlush (show ev)
  nextevent >>= penReady

getXYinSVG :: JSVal -> (Double, Double) -> IO (Double, Double)
getXYinSVG svg (x0, y0) = do
  r <- J.js_to_svg_point svg x0 y0
  [x, y] <- fromJSValUncheckedListOf r
  pure (x, y)

eraserReady :: AllEvent -> MainCoroutine ()
eraserReady ev = do
  case ev of
    ToPenMode -> nextevent >>= penReady
    PointerDown (x0, y0) -> do
      HoodleState svg _ _ _ _ _ <- get
      (x, y) <- liftIO $ getXYinSVG svg (x0, y0)
      erasingMode [] (x, y)
    _ -> pure ()
  nextevent >>= eraserReady

drawingMode :: Seq (Double, Double) -> MainCoroutine ()
drawingMode xys = do
  ev <- nextevent
  case ev of
    PointerMove xy@(x, y) -> do
      HoodleState _svg cvs offcvs _ _ _ <- get
      case viewr xys of
        _ :> (x0, y0) -> liftIO $ J.js_overlay_point cvs offcvs x0 y0 x y
        _ -> pure ()
      drawingMode (xys |> xy)
    PointerUp xy -> do
      HoodleState svg _ _ sock _ _ <- get
      let xys' = xys |> xy
      path_arr <-
        liftIO $
          J.js_to_svg_point_array svg =<< toJSValListOf (toList xys')
      path <- liftIO $ fromJSValUncheckedListOf path_arr
      modify' (\s -> s {_hdlstateSyncState = SyncState [path]})
      let hsh = hash path
          msg = NewStroke (hsh, path)
      liftIO $ WS.send (JSS.pack . T.unpack . serialize $ msg) sock
    _ -> drawingMode xys

erasingMode :: [Int] -> (Double, Double) -> MainCoroutine ()
erasingMode hitted0 (x0, y0) = do
  ev <- nextevent
  case ev of
    PointerMove (cx, cy) -> do
      HoodleState svg _ _ _ (DocState _ strks) _ <- get
      (x, y) <- liftIO $ getXYinSVG svg (cx, cy)
      let !hitted = map fst $ filter (doesLineHitStrk ((x0, y0), (x, y)) . snd) strks
          !hitted' = nub $ sort (hitted ++ hitted0)
      -- liftIO $ putStrLnAndFlush $ show $ ((x0, y0), (x, y))
      -- liftIO $ putStrLnAndFlush $ show (map fst strksHitted)
      erasingMode hitted' (x, y)
    PointerUp _ ->
      liftIO $ putStrLnAndFlush $ show hitted0
    _ -> erasingMode hitted0 (x0, y0)

initmc :: MainObj ()
initmc = ReaderT $ (\(Arg DoEvent ev) -> guiProcess ev)

setupCallback :: EventVar -> IO HoodleState
setupCallback evar = do
  putStrLn "ghcjs started"
  J.js_prevent_default_touch_move
  svg <- J.js_svg_box
  cvs <- J.js_document_getElementById "overlay"
  J.js_fix_dpi cvs
  offcvs <- J.js_create_canvas
  w <- J.js_get_width cvs
  h <- J.js_get_height cvs
  J.js_set_width offcvs w
  J.js_set_height offcvs h
  putStrLn "websocket start"
  let wsClose _ =
        putStrLnAndFlush "connection closed"
      wsMessage ev msg = do
        let d = ME.getData msg
        case d of
          ME.StringData s -> onMessage ev s
          _ -> pure ()
  xstate <- mdo
    sock <-
      WS.connect
        WS.WebSocketRequest
          { WS.url = "ws://192.168.1.42:7080",
            WS.protocols = [],
            WS.onClose = Just wsClose,
            WS.onMessage = Just (wsMessage evar)
          }
    pure $ HoodleState svg cvs offcvs sock (DocState 0 []) (SyncState [])
  onpointerdown <- syncCallback1 ThrowWouldBlock (onPointerDown evar)
  J.js_addEventListener cvs "pointerdown" onpointerdown
  onpointermove <- syncCallback1 ThrowWouldBlock (onPointerMove evar)
  J.js_addEventListener cvs "pointermove" onpointermove
  onpointerup <- syncCallback1 ThrowWouldBlock (onPointerUp evar)
  J.js_addEventListener cvs "pointerup" onpointerup
  mdo
    rAF <- syncCallback ThrowWouldBlock (test cvs offcvs rAF)
    J.js_requestAnimationFrame rAF
  radio_pen <- J.js_document_getElementById "pen"
  radio_eraser <- J.js_document_getElementById "eraser"
  J.js_addEventListener radio_pen "click" =<< syncCallback1 ThrowWouldBlock (onModeChange ModePen evar)
  J.js_addEventListener radio_eraser "click" =<< syncCallback1 ThrowWouldBlock (onModeChange ModeEraser evar)
  pure xstate

main :: IO ()
main = do
  putStrLn "new start"
  evar <- newEmptyMVar :: IO EventVar
  xstate <- setupCallback evar
  putMVar evar . Just $ D.driver simplelogger (world xstate initmc)
