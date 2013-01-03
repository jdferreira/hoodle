#!/bin/bash 

sudo apt-get install cadaver libghc-hscolour-dev libghc-hstringtemplate-dev gtk2hs-buildtools libghc-gtk-dev libghc-gtk-doc 

mkdir deps
git clone https://github.com/wavewave/devadmin.git deps/devadmin
cd deps/devadmin ; cabal install ; cd ../../
$HOME/.cabal/bin/build cloneall --config=build.conf

#cabal install gtk2hs-buildtools
$HOME/.cabal/bin/build bootstrap --config=build.conf

build haddockboot 

echo "machine $SRVR"'\n'"login $SRVRID"'\n'"password $SRVRPKEY" > $HOME/.netrc 
chmod 0600 $HOME/.netrc 

tar cvzf hoodle-core.tar.gz $HOME/.cabal/share/doc/hoodle* $HOME/.cabal/share/doc/xournal* $HOME/.cabal/share/doc/coroutine-object*
echo "open http://$SRVR:$SRVRPORT$SRVRDIR"'\n'"put hoodle-core.tar.gz"'\n'" "  > script 

cadaver < script  

rm script 
rm $HOME/.netrc 

