" ApexLink - P2P collaborative editing for Neovim
" Maintainer: StackApe
" License: MIT

if exists('g:loaded_apexlink')
  finish
endif
let g:loaded_apexlink = 1

" Don't auto-setup - user must call require('apexlink').setup() explicitly
" This prevents config breakage if daemon isn't installed
