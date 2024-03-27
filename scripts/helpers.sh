if [ -d "$HOME/.tmux/resurrect" ]; then
	default_resurrect_dir="$HOME/.tmux/resurrect"
else
	default_resurrect_dir="${XDG_DATA_HOME:-$HOME/.local/share}"/tmux/resurrect
fi
resurrect_dir_option="@resurrect-dir"

SUPPORTED_VERSION="1.9"
RESURRECT_FILE_PREFIX="tmux_resurrect"
RESURRECT_FILE_EXTENSION="txt"
_RESURRECT_DIR=""
_RESURRECT_FILE_PATH=""

d=$'\t'

# helper functions
get_tmux_option() {
	local option="$1"
	local default_value="$2"
	local option_value=$(tmux show-option -gqv "$option")
	if [ -z "$option_value" ]; then
		echo "$default_value"
	else
		echo "$option_value"
	fi
}

# Ensures a message is displayed for 5 seconds in tmux prompt.
# Does not override the 'display-time' tmux option.
display_message() {
	local message="$1"

	# display_duration defaults to 5 seconds, if not passed as an argument
	if [ "$#" -eq 2 ]; then
		local display_duration="$2"
	else
		local display_duration="5000"
	fi

	# saves user-set 'display-time' option
	local saved_display_time=$(get_tmux_option "display-time" "750")

	# sets message display time to 5 seconds
	tmux set-option -gq display-time "$display_duration"

	# displays message
	tmux display-message "$message"

	# restores original 'display-time' value
	tmux set-option -gq display-time "$saved_display_time"
}

supported_tmux_version_ok() {
	$CURRENT_DIR/check_tmux_version.sh "$SUPPORTED_VERSION"
}

remove_first_char() {
	echo "$1" | cut -c2-
}

capture_pane_contents_option_on() {
	local option="$(get_tmux_option "$pane_contents_option" "off")"
	[ "$option" == "on" ]
}

files_differ() {
	! cmp -s "$1" "$2"
}

get_grouped_sessions() {
	local grouped_sessions_dump="$1"
	export GROUPED_SESSIONS="${d}$(echo "$grouped_sessions_dump" | cut -f2 -d"$d" | tr "\\n" "$d")"
}

is_session_grouped() {
	local session_name="$1"
	[[ "$GROUPED_SESSIONS" == *"${d}${session_name}${d}"* ]]
}

# pane content file helpers

pane_contents_create_archive() {
	tar cf - -C "$(resurrect_dir)/save/" ./pane_contents/ |
		gzip >"$(pane_contents_archive_file)"
}

pane_content_files_restore_from_archive() {
	local archive_file="$(pane_contents_archive_file)"
	if [ -f "$archive_file" ]; then
		mkdir -p "$(pane_contents_dir "restore")"
		gzip -d <"$archive_file" |
			tar xf - -C "$(resurrect_dir)/restore/"
	fi
}

# path helpers
function get_parsed_resurrect_path() {
	local path="$1"
	shift
	local env_vars=("$@")

	for env_var in "${env_vars[@]}"; do
		local env_value
		env_value=$(eval echo "${env_var}")
		path="${path//${env_var}/${env_value}}"
	done
	echo "${path}"
}

expand_envs_in_path() {
	# expands all environment variables in path and additonal envs
	local path
	path="$1"

	delimiter="/"
	current_index=0
	# envs=()

	while [[ $current_index -lt ${#path} ]]; do
		end_index=$((current_index + 1))
		while [[ $end_index -lt ${#path} && "${path:$end_index:1}" != "$delimiter" ]]; do
			end_index=$((end_index + 1))
		done
		env_var="${path:current_index:end_index-current_index}"
		if [[ ${env_var:0:1} == "$" ]]; then
			# envs+=("$env_var")
			env_value=$(eval echo "${env_var}")
			path="${path//${env_var}/${env_value}}"
		fi
		current_index=$end_index+1
	done

	additional_envs=()
	additional_envs+=("~")
	path="$(get_parsed_resurrect_path "$path" "${additional_envs[@]}")"
	echo "${path}"
}

resurrect_dir() {
	if [ -z "$_RESURRECT_DIR" ]; then
		local path="$(get_tmux_option "$resurrect_dir_option" "$default_resurrect_dir")"
		local expanded_path
		expanded_path=$(expand_envs_in_path "$path")
		echo "$expanded_path"
	else
		echo "$_RESURRECT_DIR"
	fi
}
_RESURRECT_DIR="$(resurrect_dir)"

resurrect_file_path() {
	if [ -z "$_RESURRECT_FILE_PATH" ]; then
		local timestamp="$(date +"%Y%m%dT%H%M%S")"
		echo "$(resurrect_dir)/${RESURRECT_FILE_PREFIX}_${timestamp}.${RESURRECT_FILE_EXTENSION}"
	else
		echo "$_RESURRECT_FILE_PATH"
	fi
}
_RESURRECT_FILE_PATH="$(resurrect_file_path)"

last_resurrect_file() {
	echo "$(resurrect_dir)/last"
}

pane_contents_dir() {
	echo "$(resurrect_dir)/$1/pane_contents/"
}

pane_contents_file() {
	local save_or_restore="$1"
	local pane_id="$2"
	echo "$(pane_contents_dir "$save_or_restore")/pane-${pane_id}"
}

pane_contents_file_exists() {
	local pane_id="$1"
	[ -f "$(pane_contents_file "restore" "$pane_id")" ]
}

pane_contents_archive_file() {
	echo "$(resurrect_dir)/pane_contents.tar.gz"
}

execute_hook() {
	local kind="$1"
	shift
	local args="" hook=""

	hook=$(get_tmux_option "$hook_prefix$kind" "")

	# If there are any args, pass them to the hook (in a way that preserves/copes
	# with spaces and unusual characters.
	if [ "$#" -gt 0 ]; then
		printf -v args "%q " "$@"
	fi

	if [ -n "$hook" ]; then
		eval "$hook $args"
	fi
}
