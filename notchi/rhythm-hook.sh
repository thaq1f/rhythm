#!/bin/bash
# Rhythm Hook - forwards Claude Code events to Rhythm app via Unix socket
# Supports bidirectional communication for permission decisions via PreToolUse

SOCKET_PATH="/tmp/rhythm.sock"
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
    export RHYTHM_TTY=""
else
    export RHYTHM_TTY="/dev/$CLAUDE_TTY_RAW"
fi

export RHYTHM_INTERACTIVE="$IS_INTERACTIVE"
export RHYTHM_PID="$PPID"
export RHYTHM_SOCK="$SOCKET_PATH"

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

tty = os.environ.get('RHYTHM_TTY', '') or None
pid_str = os.environ.get('RHYTHM_PID', '')
pid = int(pid_str) if pid_str.isdigit() else None

tool = input_data.get('tool_name', '')

# PreToolUse is the ONLY blocking hook that supports allow/deny responses.
# PermissionRequest is informational (non-blocking).
# We ask the server to decide: respond immediately for safe tools,
# or hold the connection for user approval on dangerous ones.
needs_response = (hook_event == 'PreToolUse')

output = {
    'session_id':      input_data.get('session_id', ''),
    'cwd':             input_data.get('cwd', ''),
    'event':           hook_event,
    'status':          input_data.get('status', status_map.get(hook_event, 'unknown')),
    'pid':             pid,
    'tty':             tty,
    'interactive':     os.environ.get('RHYTHM_INTERACTIVE', 'true') == 'true',
    'permission_mode': input_data.get('permission_mode', 'default'),
    'needs_response':  needs_response,
}

if hook_event == 'UserPromptSubmit':
    prompt = input_data.get('prompt', '')
    if prompt:
        output['user_prompt'] = prompt

if hook_event in ('Stop', 'SubagentStop'):
    result = input_data.get('result', '')
    if result:
        output['result'] = result

if tool:
    output['tool'] = tool

tool_id = input_data.get('tool_use_id', '')
if tool_id:
    output['tool_use_id'] = tool_id

tool_input = input_data.get('tool_input', {})
if tool_input:
    output['tool_input'] = tool_input

RESPONSE_TIMEOUT = 120  # seconds — generous timeout for user interaction

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(os.environ['RHYTHM_SOCK'])
    sock.sendall(json.dumps(output).encode())
    sock.shutdown(socket.SHUT_WR)  # signal: done sending, keep open for response

    if needs_response:
        sock.settimeout(RESPONSE_TIMEOUT)
        chunks = []
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
        if chunks:
            response = b''.join(chunks).decode()
            # Print to stdout — Claude Code reads hook stdout for decisions
            print(response)
    else:
        sock.close()
except socket.timeout:
    # User didn't respond in time; exit silently.
    # Claude Code falls through to its default terminal prompt.
    pass
except Exception:
    pass
PYEOF

/usr/bin/python3 -c "$PYSCRIPT"
