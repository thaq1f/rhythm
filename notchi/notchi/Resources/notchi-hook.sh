#!/bin/bash
# Notchi Hook - forwards Claude Code events to Notchi app via Unix socket

SOCKET_PATH="/tmp/notchi.sock"
[ -S "$SOCKET_PATH" ] || exit 0

# Detect non-interactive sessions (claude -p / --print)
IS_INTERACTIVE=true
for CHECK_PID in $PPID $(ps -o ppid= -p $PPID 2>/dev/null | tr -d ' '); do
    if ps -o args= -p "$CHECK_PID" 2>/dev/null | grep -qE '(^| )(-p|--print)( |$)'; then
        IS_INTERACTIVE=false
        break
    fi
done

# Resolve the tty of the parent claude process
CLAUDE_TTY_RAW=$(ps -p "$PPID" -o tty= 2>/dev/null | tr -d ' ')
if [ "$CLAUDE_TTY_RAW" = "??" ] || [ -z "$CLAUDE_TTY_RAW" ]; then
    export NOTCHI_TTY=""
else
    export NOTCHI_TTY="/dev/$CLAUDE_TTY_RAW"
fi

export NOTCHI_INTERACTIVE="$IS_INTERACTIVE"
export NOTCHI_PID="$PPID"
export NOTCHI_SOCK="$SOCKET_PATH"

# Store the Python script in a variable so stdin stays free for Claude Code's JSON.
read -r -d '' PYSCRIPT << 'PYEOF'
import json, os, socket, sys

try:
    input_data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

hook_event = os.environ.get('CLAUDE_HOOK_EVENT', os.environ.get('HOOK_EVENT_NAME', ''))
if not hook_event:
    hook_event = input_data.get('hook_event_name', input_data.get('event', ''))

status_map = {
    'SessionStart':      'session_started',
    'UserPromptSubmit':  'waiting_for_input',
    'PreToolUse':        'tool_starting',
    'PostToolUse':       'tool_complete',
    'Stop':              'completed',
    'SubagentStop':      'waiting_for_input',
}

tty = os.environ.get('NOTCHI_TTY', '') or None
pid_str = os.environ.get('NOTCHI_PID', '')
pid = int(pid_str) if pid_str.isdigit() else None

output = {
    'session_id':      input_data.get('session_id', ''),
    'cwd':             input_data.get('cwd', ''),
    'event':           hook_event,
    'status':          input_data.get('status', status_map.get(hook_event, 'unknown')),
    'pid':             pid,
    'tty':             tty,
    'interactive':     os.environ.get('NOTCHI_INTERACTIVE', 'true') == 'true',
    'permission_mode': input_data.get('permission_mode', 'default'),
}

if hook_event == 'UserPromptSubmit':
    prompt = input_data.get('prompt', '')
    if prompt:
        output['user_prompt'] = prompt

if hook_event in ('Stop', 'SubagentStop'):
    result = input_data.get('result', '')
    if result:
        output['result'] = result

tool = input_data.get('tool_name', '')
if tool:
    output['tool'] = tool

tool_id = input_data.get('tool_use_id', '')
if tool_id:
    output['tool_use_id'] = tool_id

tool_input = input_data.get('tool_input', {})
if tool_input:
    output['tool_input'] = tool_input

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(os.environ['NOTCHI_SOCK'])
    sock.sendall(json.dumps(output).encode())
    sock.close()
except Exception:
    pass
PYEOF

/usr/bin/python3 -c "$PYSCRIPT"
