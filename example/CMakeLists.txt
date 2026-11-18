cmake_minimum_required(VERSION 4.0)
project(cpp26_demo LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 26)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(CPP26_DEMO_SANITIZE "Build with AddressSanitizer and UndefinedBehaviorSanitizer" OFF)

add_executable(cpp26_demo src/main.cpp)
target_compile_options(cpp26_demo PRIVATE -Wall -Wextra -Wpedantic)

if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL 16)
  # GCC 16 implements C++26 static reflection but still gates it behind -freflection.
  # Its default contract-violation handler lives in libstdc++exp.
  target_compile_options(cpp26_demo PRIVATE -freflection)
  target_link_libraries(cpp26_demo PRIVATE stdc++exp)
endif()

if(CPP26_DEMO_SANITIZE)
  set(sanitizers -fsanitize=address,undefined -fno-sanitize-recover=all)
  target_compile_options(cpp26_demo PRIVATE ${sanitizers} -fno-omit-frame-pointer)
  target_link_options(cpp26_demo PRIVATE ${sanitizers})
endif()

enable_testing()
add_test(NAME run COMMAND cpp26_demo)

# Valgrind can't run sanitized binaries, so memcheck only applies to plain builds.
find_program(VALGRIND_EXECUTABLE valgrind)
if(VALGRIND_EXECUTABLE AND NOT CPP26_DEMO_SANITIZE)
  add_test(NAME memcheck
           COMMAND ${VALGRIND_EXECUTABLE} --quiet --error-exitcode=1 --leak-check=full
                   --errors-for-leak-kinds=definite,indirect $<TARGET_FILE:cpp26_demo>)
endif()

# cppcheck analyzes every #ifdef configuration. Version 2.22 can't parse contracts
# (pre/post) or reflection (^^) yet, so skip the configurations that enable them.
find_program(CPPCHECK_EXECUTABLE cppcheck)
if(CPPCHECK_EXECUTABLE)
  add_test(NAME cppcheck
           COMMAND ${CPPCHECK_EXECUTABLE} --project=${CMAKE_BINARY_DIR}/compile_commands.json
                   -U__cpp_contracts -U__cpp_impl_reflection
                   --enable=warning,performance,portability --inline-suppr
                   --suppress=missingIncludeSystem --error-exitcode=1 --quiet)
endif()
