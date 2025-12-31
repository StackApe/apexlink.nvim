" ApexLink - P2P collaborative editing for Neovim
" Maintainer: StackApe
" License: MIT

if exists('g:loaded_apexlink')
  finish
endif
let g:loaded_apexlink = 1

" Defer loading to lua
lua require('apexlink').setup()
