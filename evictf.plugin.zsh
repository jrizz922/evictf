#!/usr/bin/env zsh

## iCloud Drive Eviction Utility
## Evict all regular files under the current directory from local storage.
## Usage: evictf
evictf() {
	emulate -L zsh
	setopt localtraps

	# Verify that brctl is available before attempting any evictions.
	if ! command -v brctl >/dev/null 2>&1; then
		echo "evictf: brctl not found" >&2
		return 1
	fi

	# Stream find's null-delimited output through a FIFO while preserving its
	# exit status via the background process PID.
	local file find_tmpdir find_fifo find_pid find_ppid find_start find_status
	local attempted=0 succeeded_count=0 failed_count=0
	local progress_tty=0 summary_fd=1
	find_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/evictf.XXXXXX") || {
		echo "evictf: could not create temporary directory" >&2
		return 1
	}
	chmod 700 "$find_tmpdir" || {
		rm -rf -- "$find_tmpdir"
		echo "evictf: could not secure temporary directory" >&2
		return 1
	}
	find_fifo="$find_tmpdir/find.fifo"
	if ! mkfifo "$find_fifo"; then
		rm -rf -- "$find_tmpdir"
		echo "evictf: could not create temporary FIFO" >&2
		return 1
	fi
	cleanup() {
		if [[ -n "$find_pid" ]]; then
			if [[ -n "$find_ppid" && -n "$find_start" ]]; then
				# Verify ownership and start time before signalling. This avoids
				# targeting an unrelated process if the PID has been reused.
				local current_ppid current_start
				current_ppid=$(ps -p "$find_pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
				current_start=$(ps -p "$find_pid" -o lstart= 2>/dev/null | tr -d '[:space:]')
				if [[ "$current_ppid" == "$find_ppid" && "$current_start" == "$find_start" ]]; then
					kill "$find_pid" 2>/dev/null
				fi
			fi
			wait "$find_pid" 2>/dev/null
		fi
		rm -f -- "$find_fifo"
		rm -rf -- "$find_tmpdir"
	}
	trap cleanup EXIT INT TERM
	find . -type f -print0 > "$find_fifo" &
	find_pid=$!
	find_ppid=$$
	find_start=$(ps -p "$find_pid" -o lstart= 2>/dev/null | tr -d '[:space:]')
	if [[ -t 2 ]]; then
		progress_tty=1
		summary_fd=2
	fi
	while IFS= read -r -d $'\0' file; do
		# Attempt every file, recording failures instead of stopping at the first
		# error so that the entire directory tree is processed.
		if brctl evict "$file"; then
			((succeeded_count++))
		else
			((failed_count++))
		fi
		((attempted++))
		# Display live progress only when stderr is an interactive terminal.
		if ((progress_tty)); then
			printf '\rEviction progress: %d attempted, %d succeeded, %d failed' \
				"$attempted" "$succeeded_count" "$failed_count" >&2
		fi
	done < "$find_fifo"
	wait "$find_pid"
	find_status=$?
	find_pid=
	cleanup
	trap - EXIT INT TERM
	if ((progress_tty)); then
		printf '\n' >&2
	fi
	printf 'Eviction summary: %d attempted, %d succeeded, %d failed\n' \
		"$attempted" "$succeeded_count" "$failed_count" >&$summary_fd

	# Return failure after all attempts if any individual eviction failed.
	if ((failed_count > 0)); then
		echo "evictf: failed to evict $failed_count file(s)" >&2
	fi
	if ((find_status != 0)); then
		echo "evictf: find failed while scanning the directory (status $find_status)" >&2
	fi
	if ((failed_count > 0 || find_status != 0)); then
		return 1
	fi
}
