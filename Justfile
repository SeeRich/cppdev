default:
    just --list

# Build the image; extra args go to docker build (e.g. --build-arg JOBS=8)
docker-build *args:
    docker build --progress=plain -t cppdev:latest {{args}} . 2>&1 | tee build.log

docker-run:
    docker run --rm -it cppdev:latest

docker-push tagname:
    @docker tag cppdev:latest seerich/cppdev:{{tagname}}
    @docker push seerich/cppdev:{{tagname}}

# Build, test and run the C++26 example with GCC and Clang inside the image
example image="cppdev:latest" *presets:
    CPPDEV_IMAGE={{image}} ./example/run.sh {{presets}}
