{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Hoodle.Coroutine.LaTeX
-- Copyright   : (c) 2011-2014 Ian-Woo Kim
--
-- License     : GPL-3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module Hoodle.Coroutine.LaTeX where

import Control.Applicative
import Control.Lens
import Control.Monad.IO.Class
import Control.Monad.Trans.Maybe
import Control.Monad.State
import qualified Data.ByteString.Char8 as B
import           Data.Function (on)
import qualified Data.HashMap.Strict as HM
import Data.List (sortBy)
import Data.Maybe
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
-- 
import Data.Hoodle.Generic
import Data.Hoodle.Simple
import Graphics.Hoodle.Render.Type.Hoodle (rHoodle2Hoodle)
--
import Hoodle.ModelAction.Text
import Hoodle.Type.Coroutine
import Hoodle.Type.HoodleState


hoistMaybe = MaybeT . return

getLaTeXComponentsFromHdl :: Hoodle -> [(Maybe T.Text,(Int,Double,T.Text))] 
getLaTeXComponentsFromHdl hdl = 
    let mlatex_components = do 
          (pgnum,pg) <- (zip ([1..] :: [Int]) . view pages) hdl  
          l <- view layers pg
          i <- view items l
          case i of 
            ItemSVG svg -> 
              runMaybeT $ do
                v <- hoistMaybe (svg_command svg)
                guard (v == "latex")
                svgtextbstr <- hoistMaybe (svg_text svg)
                let (_,y) = svg_pos svg  
                    svgtext = TE.decodeUtf8 svgtextbstr
                    mk = extractKeyword svgtext
                return (mk,(pgnum,y,svgtext))
            _ -> []
        cfunc :: (Ord a,Ord b,Ord c) => (a,b,c) -> (a,b,c) -> Ordering 
        cfunc x y | view _1 x > view _1 y = GT
                  | view _1 x < view _1 y = LT
                  | otherwise = if | view _2 x > view _2 y -> GT
                                   | view _2 x < view _2 y -> LT
                                   | otherwise -> EQ
        latex_components = catMaybes  mlatex_components
        sorted = sortBy (cfunc `on` snd) latex_components 
    in sorted

{- 
updateLaTeX :: MainCoroutine ()
updateLaTeX = do
    liftIO $ putStrLn "updateLaTeX called"
    rhdl <- getHoodle <$> get
    let hdl = rHoodle2Hoodle rhdl
    runMaybeT $ do 
      {- txtsrc <- -} MaybeT $ return (rhdl ^. gembeddedtext)  
      -- let km = getKeywordMap txtsrc
      -- liftIO $ print km
    -- let sorted = getLaTeXComponentsFromHdl hdl
    -- liftIO $ print sorted 
    return ()
-}

laTeXHeader :: T.Text
laTeXHeader = 
  "\\documentclass[a4paper]{article}\n\
  \\\usepackage[affil-it]{authblk}\n\
  \\\usepackage{xeCJK}\n\
  \\\xeCJKsetup{\n\
  \  CJKspace=true,\n\
  \  CJKecglue={}\n\
  \}\n\
  \\\usepackage{setspace}\n\
  \\\onehalfspacing\n\
  \\\usepackage{fontspec}\n\
  \\\setCJKmainfont{NanumGothic}\n\
  \\\usepackage{minted}\n\
  \\\pagestyle{empty}\n\
  \\\begin{document}\n"


-- \\\\documentclass{article}\n\
--              \\\pagestyle{empty}\n\
--              \\\begin{document}\n
                                
laTeXFooter :: T.Text
laTeXFooter = "\\end{document}\n"
