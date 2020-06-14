{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Hoodle.Coroutine.HubInternal where

import           Control.Applicative
import qualified Control.Exception as E
import           Control.Lens (view)
import           Control.Monad (unless)
import           Control.Monad.IO.Class
import           Control.Monad.State
import           Control.Monad.Trans.Maybe
import           Data.Aeson as AE
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Foldable as F
import qualified Data.HashMap.Strict as H
import qualified Data.List as L
import Data.Monoid ((<>))
import Data.Text (Text,pack,unpack)
import Data.Text.Encoding (encodeUtf8,decodeUtf8)
import Data.Time.Calendar
import Data.Time.Clock
import Data.UUID.V4
import Network
import Network.Google.OAuth2 (formUrl, exchangeCode, refreshTokens,
                               OAuth2Client(..), OAuth2Tokens(..))
import Network.Google (makeRequest, doRequest)
import Network.HTTP.Conduit
import Network.HTTP.Types (methodPut)
import System.Directory
import System.Environment (getEnv)
import System.Exit    (ExitCode(..))
import System.FilePath ((</>),(<.>),makeRelative)
import System.Info (os)
import System.Process (system, rawSystem,readProcessWithExitCode)
--
import Data.Hoodle.Simple
import Graphics.Hoodle.Render.Type.Hoodle
import Text.Hoodle.Builder (builder)
--
import Hoodle.Coroutine.Draw
import Hoodle.Script.Hook
import Hoodle.Type.Coroutine
import Hoodle.Type.Event
import Hoodle.Type.Hub
import Hoodle.Type.HoodleState
import Hoodle.Util


uploadWork :: (FilePath,FilePath) -> HubInfo -> MainCoroutine ()
