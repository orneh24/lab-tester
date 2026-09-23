# /etc/profile.d/mesh-probe-status.sh — show the last test cycle plus a
# usage hint at interactive login. Same guard as
# mesh-probe-node-setup.sh (login-setup.sh): interactive shells with a real
# tty only, so it never fires for scp/rsync/non-interactive SSH commands —
# see CLAUDE.md constraint 16.

case "$-" in
    *i*)
        if [ -t 0 ] && [ -f /etc/mesh-probe/.setup-done ]; then
            echo
            echo "Last test cycle:"
            /usr/local/bin/test-status 2>/dev/null || cat /run/mesh-probe/last-cycle.txt 2>/dev/null
            echo
            echo "test-status [-f|--follow] [-n N]   -- view this node's own test results"
            echo
        fi
        ;;
esac
