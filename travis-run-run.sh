# Copyright (C) 2014  Daniel Gröber <dxld ÄT darkboxed DOT org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# This script will be sourced by travis-run

if [ ! -e .travis.yml ]; then
    echo "Error: .travis.yml does not exist.">&2
    exit 1
fi

if [ "$1" ]; then
    BUILD_ID="$1"; shift
else
    unset BUILD_ID
fi

if [ "$1" ]; then
    error "Error: Unexpected arguments: \`$@'"
    exit 1
fi

CANCELLED=false

if [ ! "$OPT_KEEP" ]; then
    trap '$INITIALIZED && CANCELLED=true && trap - INT && echo && backend_end '"$OPT_VM_NAME"'' INT

    trap '$INITIALIZED && ! "$CANCELLED" && backend_end '"$OPT_VM_NAME" EXIT

    trap '$INITIALIZED && backend_end '"$OPT_VM_NAME" TERM

    backend_end "$OPT_VM_NAME"
fi

INITIALIZED=false

init () {
    "$INITIALIZED" && return

    INITIALIZED=true

    backend_init "$OPT_VM_NAME"

    if [ $? -ne 0 ]; then
	echo "Starting VM failed">&2
	exit 1
    fi
}

run_tests () {
    label="$1"
    cfg="$2"

    local script
    script=$(printf '%s\n' "$cfg" \
	| backend_run_script "$OPT_VM_NAME" --build 2>/dev/null)

    RV=$?

    if $CANCELLED; then
    	debug "Generating build script cancelled." >&2
        return 1
    else
	if [ $RV != 0 ]; then
    	    info "Error: Generating build script failed." >&2
	    return 1
	fi
    fi

    # Save environment just before exiting so we can restore it when launching
    # the debugging shell
    travis_terminate=$(cat <<EOF
#!/bin/bash
travis_terminate() {
  env | sed -e '/PWD\|OLDPWD/d' -e 's/\(.*\)=\(.*\)/export \1="\2"/' >> ~/.profile;
  pkill -9 -P \$$ &> /dev/null || true;
  exit \$1;
};
EOF
)

    #remove definition of travis_terminate
    script=$(printf '%s\n' "$script" \
        | sed '/travis_terminate() {/,/}/d' \
        | sed '/^#!/d')


    script="${travis_terminate} ${script}"

    mkdir -p ".travis-run"
    fifo .travis-run/run_fifo

    printf '%s' "$script" | backend_run "$OPT_VM_NAME" copy -- bash \
	> .travis-run/run_fifo 2>&1 &

    BUILD_PID=$!

    # 1) the build script doesn't terminate it's ANSI colors
    # 2) remove lone CR's (they use them for folding metadata)
    perl -pe '$|=1; s/(\x1b\[[^m]+.*)/\1\x1b[0m/g; s/\r/\n/g' \
	< .travis-run/run_fifo 1>&2 &

    wait $!
    wait $BUILD_PID
    RV=$?
    unset BUILD_PID


    if ! $CANCELLED; then
        if [ $RV -ne 0 ]; then
    	    error "Build failed, please investigate." >&2
            info "Current build: \"$label\""

	    backend_run "$OPT_VM_NAME" nocopy

            rm -f ".travis-run/run_fifo"
	    return 1
        fi

        info "Build Succeeded :)\n\n\n" >&2
    else
        debug "Build cancelled :(\n\n\n"
        rm -f ".travis-run/run_fifo"
        return 1
    fi
}

if [ $OPT_SHELL ]; then
    init
    backend_run "$OPT_VM_NAME" copy
    exit
fi

cfgs=$(backend_run_script "$OPT_VM_NAME" < .travis.yml)
id=0
while true; do
    line="$(printf '%s' "$cfgs" | sed '1q')"
    cfgs="$(printf '%s' "$cfgs" | sed '1d')"

    [ ! "$line" ] && break

    unset label; unset cfg
    eval $(printf '%s' "$line")
    [ ! "$cfg" ] && continue

    if [ "$BUILD_ID" = "$(printf "$BUILD_ID" | tr -dc '[0-9]')" ]; then
	num=1
    else
	num=0
    fi

    if [ ! "$BUILD_ID" ] \
	|| [ x"$BUILD_ID" = x"$label" ] \
	|| [ x"$num" = x"1" -a x"$BUILD_ID" = x"$id" ]
    then
	init

	info "Running build: \"$label\""

	run_tests "$label" "$cfg"
	if [ $? -ne 0 ]; then
	    exit $?
	fi
    fi

    id=$(($id + 1))
done

exit 0
