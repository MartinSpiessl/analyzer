# goblint
[![Travis Build Status](https://travis-ci.com/goblint/analyzer.svg?branch=master)](https://travis-ci.com/goblint/analyzer) <!-- [![Circle CI](https://circleci.com/gh/goblint/analyzer.svg?style=svg)](https://circleci.com/gh/goblint/analyzer) --> [![Docker Build Status](https://img.shields.io/docker/build/voglerr/goblint)](https://hub.docker.com/r/voglerr/goblint)

## Setup
**For an up-to-date-version, clone this repository, use `make setup` to install OCaml and all dependencies, and `make` to build.**

Alternatively: Install [opam](http://opam.ocaml.org/doc/Install.html), and then do `opam install goblint`. Warning: The OPAM package is updated infrequently.


Run goblint: `./goblint tests/regression/04-mutex/01-simple_rc.c`.

If something goes wrong, take a look at [travis-ci.sh](scripts/travis-ci.sh) for an example Ubuntu/macOS setup.

### macOS
Goblint relies on GNU `cpp` to preprocess source files - the default clang `cpp` on macOS will not work.
You can install it with `brew install gcc` (first do `xcode-select --install` if you don't want to build from source). You can check src/config.ml to see what command is used to call `cpp`.

### Windows
For Windows 10 we recommend using [WSL](https://docs.microsoft.com/de-de/windows/wsl/install-win10).
For older versions you can try to build using [these scripts](https://github.com/goblint/analyzer/tree/master/scripts/old/cygwin) for Cygwin, or use a virtual machine.

### Docker / Virtual machine
You can run Goblint in a [Docker container](https://hub.docker.com/r/voglerr/goblint/) using: `docker run -it voglerr/goblint ./goblint --help`.

A virtual machine containing Goblint can be set up using [Vagrant](http://www.vagrantup.com/): `vagrant up && vagrant ssh`.

### Web frontend
The analysis results are printed to stdout by default.
Adding `--html` saves the results as XML, which is then transformed to be viewable in a web browser.
Use `make jar` to build the needed Java program.

    ./goblint --html path/to/file.c

Open `result/index.xml` in a browser of your choice.
Depending on the browser security settings, it might be necessary to serve the result directory from a webserver to access it.
This can be done by e.g. running `python3 -m http.server` in the `result` directory. The results should then be accessible at `http://localhost:8000`

<!-- ### Web frontend -->
<!-- Use `make npm` to setup the web frontend and start serving on <http://localhost:3000>. -->
<!-- See its [README](https://github.com/vogler/goblint-webapp) for details. -->
