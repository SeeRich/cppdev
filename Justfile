default:
    just --list

docker-build:
    docker build --progress=plain -t cppdev:latest . 2>&1 | tee build.log

docker-run:
    docker run --rm -it cppdev:latest

docker-push tagname:
    @docker tag cppdev:latest seerich/cppdev:{{tagname}}
    @docker push seerich/cppdev:{{tagname}}