PROJECT(luajit-async)
#to allow install from subdirectory
cmake_minimum_required(VERSION 3.13)


INSTALL(DIRECTORY lj-async/ DESTINATION ${LUAJIT_BIN}/lua/lj-async)
INSTALL(FILES pthread/pthread.lua DESTINATION ${LUAJIT_BIN}/lua)