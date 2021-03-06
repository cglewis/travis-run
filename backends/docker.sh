backend_register_longopt "docker-base-image:"
backend_register_longopt "docker-build-stage:"
backend_register_longopt "docker-no-pull"

if [ x"$(uname)" = x"Darwin" ]; then
    debug "docker: Running on Darwin, using boot2docker."
    BOOT2DOCKER=true
else
    BOOT2DOCKER=false
fi

boot2docker_init () {
    [ -n "$DOCKER_HOST" ] && return
    if $BOOT2DOCKER; then
        if [ x"$(boot2docker status)" != x"running" ]; then
	    do_done "docker: Starting boot2docker VM (this might take a while)" \
	        boot2docker up '>/dev/null' '2>&1'

	    [ $? -ne 0 ] && exit $?
        fi

        eval "export" $(boot2docker up 2>&1 \
	    | awk -n '/export DOCKER_HOST/{print $NF}')
    fi
}

docker_check_state_dir () {
    mkdir -p ~/.travis-run

    if [ ! -d ".travis-run/$VM_NAME" ]; then
	error "travis-run: Can't find state dir:">&2
	error "    $PWD/.travis-run/$VM_NAME">&2
	error >&2
	error "Have you run \`travis-run create' yet?">&2
	exit 1
    fi
}

docker_exists () {
    docker inspect "$@" >/dev/null 2>&1
}

docker_pull () {
    if [ "$OPT_NO_PULL" ];  then
	return 1
    fi

    docker pull "$@"
    RV=$?
    echo "$@" >> ~/.travis-run/images
    return $RV
}

docker_create () {
    boot2docker_init

    local OPTS LANGUAGE OPT_DISTRIBUTION OPT_FROM OPT_STAGE

    OPTS=$($GETOPT -o "" --long docker-base-image:,docker-build-stage:,docker-no-pull -n "$(basename "$0")" -- "$@")
    eval set -- "$OPTS"

    while true; do
	case "$1" in
            --docker-base-image)  OPT_FROM=$2;     shift; shift ;;
            --docker-build-stage) OPT_STAGE=$2;    shift; shift ;;
	    --docker-no-pull)     OPT_NO_PULL=1;   shift ;;

            --) shift; break ;;
            *) error "Error parsing argument: $1">&2; exit 1 ;;
	esac
    done

    local VM_NAME VM_REPO
    VM_REPO="$1"; shift
    VM_NAME="$(basename "$VM_REPO")"

    OPT_LANGUAGE=$1; shift
    OPT_FROM=${OPT_FROM:-ubuntu:precise}
    OPT_SCRIPT_FROM=${OPT_SCRIPT_FROM:-debian:wheezy}

    if [ ! "$OPT_LANGUAGE" ]; then
	error "Usage: docker_create VM_NAME LANGUAGE [DOCKER_OPTIONS..]">&2
	exit 1
    fi

    tmpdir=$(mktemp -p "${TMPDIR:-/tmp/}" -d travis-run-XXXX) || exit 1
    trap 'rm -rf '"$tmpdir" 0

    cp -p  "$SHARE_DIR"/vm/*   "$tmpdir"
    cp -rp "$SHARE_DIR"/script "$tmpdir"
    cp -p  "$SHARE_DIR"/keys/* "$tmpdir"

    local script_tag="$VM_REPO:script_$VERSION"
    if [ -z "$OPT_STAGE" -o x"$OPT_STAGE" = x"script" ] \
        && ! docker_pull "$script_tag"
    then
	info "Creating build-script image">&2

        sed "s|\$FROM|${OPT_SCRIPT_FROM}"'|' \
	    < "$SHARE_DIR/docker/Dockerfile.script" \
	    > "$tmpdir"/Dockerfile

	docker build -t "$script_tag" "$tmpdir" || exit 1

	echo "$script_tag" >> ~/.travis-run/images
    fi

    local base_tag="$VM_REPO:base_$VERSION"
    if [ -z "$OPT_STAGE" -o x"$OPT_STAGE" = x"base" ] \
        && ! docker_pull "$base_tag"
    then
	info "Creating base image">&2

        sed "s/\$OPT_FROM/$OPT_FROM"'/' \
	    < "$SHARE_DIR/docker/Dockerfile.base" \
	    > "$tmpdir"/Dockerfile

	docker build -t "$base_tag" "$tmpdir" || exit 1

	echo "$base_tag" >> ~/.travis-run/images
    fi

    local language_tag="$VM_REPO:${OPT_LANGUAGE}_$VERSION"
    if [ -z "$OPT_STAGE" -o x"$OPT_STAGE" = x"language" ] \
        && ! docker_pull "$language_tag"
    then
	info "Creating language image"

	sed -e "s|\$FROM|$base_tag"'|' \
            -e "s/\$OPT_LANGUAGE/$OPT_LANGUAGE"'/' \
	    < "$SHARE_DIR/docker/Dockerfile.language" \
	    > "$tmpdir"/Dockerfile

	docker build -t "$language_tag" "$tmpdir" || exit 1

	echo "$language_tag" >> ~/.travis-run/images
    fi

    if [ -z "$OPT_STAGE" -o x"$OPT_STAGE" = x"project" ]; then
	info "Creating per-project image"

	mkdir -p ".travis-run/$VM_NAME"

	if [ ! -e ".travis-run/$VM_NAME/Dockerfile" ]; then
	    sed "s|\$FROM|$language_tag|" \
		< "$SHARE_DIR/docker/Dockerfile.project" \
		> ".travis-run/$VM_NAME"/Dockerfile
	fi

        fifo ".travis-run/build-stdout"

        docker build ".travis-run/$VM_NAME" 2>/dev/null \
            > ".travis-run/build-stdout" &
        local build_pid=$!

	DOCKER_ID=$(cat ".travis-run/build-stdout" \
	    | grep 'Successfully built' \
	    | awk '{ print $3 }')

        wait $build_pid
        if [ $? -ne 0 ]; then
            rm -f .travis-run/build-stdout
            exit $?
        fi

	echo "$DOCKER_ID" > ".travis-run/$VM_NAME/docker-image-id"
	echo "$DOCKER_ID" >> ~/.travis-run/images
        rm -f .travis-run/build-stdout
    fi
}

docker_destroy () {
    docker_clean "$@"

    local images
    images=$(sort < ~/.travis-run/images | uniq)

    for img in $(printf '%s' "$images"); do
	if docker_exists "$img"; then
	    docker rmi $img

	    if [ $? -ne 0 ]; then
		local offender
		offender=$(docker ps -a | grep "$img" | awk '{ print $1 }')

		if [ -n "$offender" ]; then
		    error "\
docker: Removing image \`$img' failed, looks like it's in use by container\n\
\`$offender'.\n\n\
If you're sure that container isn't doing anything important destroy it with:\n\
    $ docker stop $offender && docker rm $offender\n\
and run \`$0 destroy' again."
		else
		    error "\
docker: Removing image \`$img' failed, maybe some container is using it?\n\n\
Try \`docker ps -a' to find the running container and then \`docker {stop,rm}'\n\
to destroy the offending container."
		fi
		continue
	    fi
	fi
	images=$(printf '%s' "$images" | grep -v "^$img\$")
    done

    printf '%s' "$images" > ~/.travis-run/images
}

docker_clean () {
    local VM_NAME VM_REPO
    VM_REPO="$1"; shift
    VM_NAME="$(basename "$VM_REPO")"

    if [ -f ".travis-run/$VM_NAME/docker-container-id" ]; then
	docker_end "$VM_REPO"
    fi

    if [ -f ".travis-run/$VM_NAME/docker-image-id" ]; then
    	docker rmi "$(cat ".travis-run/$VM_NAME/docker-image-id")"
	rm -f ".travis-run/$VM_NAME/docker-image-id"
    fi
}

docker_init () {
    local VM_NAME VM_REPO
    VM_REPO="$1"; shift
    VM_NAME="$(basename "$VM_REPO")"

    local DOCKER_CONTAINER_NAME
    DOCKER_CONTAINER_NAME="travis-run_$(printf '%s' "$PWD" | sed 's|/|-|g')"

    docker_check_state_dir

    boot2docker_init || exit $?

    local DOCKER_IMG_ID=$(cat ".travis-run/$VM_NAME/docker-image-id")

    while true; do
	if [ -f ".travis-run/$VM_NAME/docker-container-id" ]; then
	    debug "docker: try running container"
	    local DOCKER_CONTAINER_ID
            DOCKER_CONTAINER_ID=$(cat ".travis-run/$VM_NAME/docker-container-id")

	    local inspect running
	    inspect=$(docker inspect "$DOCKER_CONTAINER_ID")
	    if [ $? -eq 0 ]; then
		running="$(printf '%s' "$inspect" \
                      | grep '"Running":[[:space:]]true')"

		if [ "$running" ]; then
		    info "docker: Using running container $DOCKER_CONTAINER_ID"
		    break
		else
		    do_done "docker: Starting existing container" \
			docker start "$DOCKER_CONTAINER_ID" >/dev/null
		    break
		fi
	    fi

	    debug "docker: nope, remove stale docker-container-id file"
	    rm ".travis-run/$VM_NAME/docker-container-id"
	    continue
	else
	    local listen
	    if ! $BOOT2DOCKER; then
		listen="127.0.0.1::"
	    else
		listen=""
	    fi

	    do_done "docker: Starting container from image $DOCKER_IMG_ID" \
		'DOCKER_CONTAINER_ID=$(docker run -d -p ${listen}22 \
                               --name="$DOCKER_CONTAINER_NAME" "$DOCKER_IMG_ID")'

	    echo "$DOCKER_CONTAINER_ID" \
                > ".travis-run/$VM_NAME/docker-container-id"

	    break
	fi
    done

    local addr ip port
    addr=$(docker port "$DOCKER_CONTAINER_ID" 22)
    if [ $? -ne 0 ]; then
	error "docker: getting port failed."
	exit 1
    fi

    ip=$(echo "$addr" | sed 's/:.*//')
    port=$(echo "$addr" | sed 's/.*://')

    if $BOOT2DOCKER; then
    	ip=$(boot2docker ip 2>/dev/null)

    	if [ $? -ne 0 ]; then
    	    error "docker: Couldn't get boot2docker VM ip address."
    	    exit 1
    	fi
    fi

    if [ ! -e ~/.travis-run/travis-run_id_rsa ]; then
	cp $SHARE_DIR/keys/travis-run_id_rsa     ~/.travis-run/
	cp $SHARE_DIR/keys/travis-run_id_rsa.pub ~/.travis-run/
	chmod 600 ~/.travis-run/travis-run_id_rsa
    fi

    DOCKER_SSH="env LANGUAGE= LC_ALL= LC_CTYPE= LANG=C.UTF-8 ssh -q -o CheckHostIP=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectionAttempts=10 -o ControlMaster=no -i $HOME/.travis-run/travis-run_id_rsa -p $port travis@$ip"

    do_done "docker: Waiting for ssh to come up (this takes a while)" \
	retry 3 $DOCKER_SSH -Tn -- echo hai >/dev/null
}

docker_end () {
    local VM_NAME VM_REPO
    VM_REPO="$1"; shift
    VM_NAME="$(basename "$VM_REPO")"

    [ ! -f ".travis-run/$VM_NAME/docker-container-id" ] && return

    local DOCKER_CONTAINER_ID
    DOCKER_CONTAINER_ID=$(cat ".travis-run/$VM_NAME/docker-container-id")

    docker stop -t 0 "$DOCKER_CONTAINER_ID" >/dev/null || true

    do_done "docker: Removing container $DOCKER_CONTAINER_ID" \
	docker rm "$DOCKER_CONTAINER_ID" >/dev/null || true

    rm -f ".travis-run/$VM_NAME/docker-container-id"
}

## Usage: docker_run_script VM_NAME [OPTIONS..]
docker_run_script () {
    local VM_NAME VM_REPO
    VM_REPO="$1"; shift
    VM_NAME="$(basename "$VM_REPO")"

    boot2docker_init || exit $?

    docker_check_state_dir

    do_done "docker: Generating build script" \
	docker run --rm -i "$VM_REPO:script_$VERSION" "$@"
}

## Usage: docker_run VM_NAME COPY? [OPTIONS..] -- COMMAND
docker_run () {
    local OPTS CPY

    OPTS=$($GETOPT -o "" -n "$(basename "$0")" -- "$@")
    eval set -- "$OPTS"

    while [ x"$1" != x"--" ]; do shift; done; shift

    local VM_NAME VM_REPO
    VM_REPO="$1"; shift
    VM_NAME="$(basename "$VM_REPO")"
    CPY=$1; shift

    docker_check_state_dir

    if [ ! -f ".travis-run/$VM_NAME/docker-image-id" ]; then
	error "travis-run: Can't get docker image id.">&2
	error >&2
	error "Have you run \`travis-run create' yet?">&2
	exit 1
    fi

    if [ x"$CPY" = x"copy" ]; then
	$DOCKER_SSH -nT -- "rm -rf 'build/' && mkdir -p build/"

	do_done "docker: Copying directory into container" \
	    \( git ls-files --exclude-standard --others --cached -z \
	    \| tar -c --null -T - \
	    \| $DOCKER_SSH -T -- tar -C build -x \)
    fi

    $DOCKER_SSH -- "$@"
}
