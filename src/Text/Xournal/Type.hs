{-# LANGUAGE BangPatterns, OverloadedStrings, 
             TypeFamilies, FlexibleContexts  #-}

module Text.Xournal.Type where

import qualified Data.ByteString as S
import Data.Strict.Tuple

import Prelude hiding (fst,snd,curry,uncurry)

class IStroke a where
  strokeTool :: a -> S.ByteString 
  strokeColor :: a -> S.ByteString
  strokeWidth :: a -> Double 
  strokeData :: a -> [Pair Double Double]

class (IStroke (TStroke a)) => ILayer a where
  type TStroke a :: * 
  layerStrokes :: a -> [TStroke a]

class (ILayer (TLayer a)) => IPage a where   
  type TLayer a :: * 
  pageDim :: a -> Dimension
  pageBkg :: a -> Background 
  pageLayers :: a -> [TLayer a] 

class (IPage (TPage a)) => IXournal a where
  type TPage a :: *
  xournalPages :: a -> [TPage a]

type Title = S.ByteString

data Stroke = Stroke { stroke_tool  :: !S.ByteString
                     , stroke_color :: !S.ByteString
                     , stroke_width :: !Double
                     , stroke_data  :: ![Pair Double Double]
                     }
            deriving Show

data Dimension = Dim { dim_width :: !Double, dim_height :: !Double }
               deriving Show

data Background = Background { bkg_type :: !S.ByteString 
                             , bkg_color :: !S.ByteString 
                             , bkg_style :: !S.ByteString 
                             }
                deriving Show 

data Xournal = Xournal { xoj_title :: !Title, xoj_pages :: ![Page] }
             deriving Show 

data Page = Page { page_dim :: !Dimension
                 , page_bkg :: !Background 
                 , page_layers :: ![Layer] }
          deriving Show 
data Layer = Layer { layer_strokes :: ![Stroke] } 
           deriving Show 

emptyXournal = Xournal "" [] 

instance IStroke Stroke where
  strokeTool = stroke_tool
  strokeColor = stroke_color
  strokeWidth = stroke_width
  strokeData = stroke_data
  
instance ILayer Layer where
  type TStroke Layer = Stroke
  layerStrokes = layer_strokes 

instance IPage Page where
  type TLayer Page = Layer 
  pageDim = page_dim 
  pageBkg = page_bkg 
  pageLayers = page_layers

instance IXournal Xournal where
  type TPage Xournal = Page 
  xournalPages = xoj_pages 
