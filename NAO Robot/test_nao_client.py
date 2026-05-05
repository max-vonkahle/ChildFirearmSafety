# -*- coding: utf-8 -*-

import zmq
from naoqi import ALProxy
from unidecode import unidecode







DESTINY = "192.168.1.69"
SAM = "192.168.1.128"
JOURNEY = "192.168.1.55"
ANGEL = "192.168.1.35"
TRANQUILITY = "192.168.1.30"

ROBOT_IP = JOURNEY
PORT = 9559

context = zmq.Context()

print("Connecting to hello world server...")
socket = context.socket(zmq.REQ)
socket.connect("tcp://localhost:5567")

poller = zmq.Poller()
poller.register(socket, zmq.POLLIN)

tts = ALProxy("ALTextToSpeech", ROBOT_IP, PORT)

animated_speech = ALProxy("ALAnimatedSpeech", ROBOT_IP, PORT)

tts.setParameter("speed", 83)
animated_speech.setBodyLanguageMode(2)



cancel = False


# =====================================================
#  NAOqi-safe string helper (Python2)
# =====================================================
def nao_str(x):
    """
    Return a Python2 'str' (bytes) safe for NAOqi.
    - If unicode -> encode utf-8
    - If str -> return as-is
    - Else -> stringify
    """
    if x is None:
        return "Okay."
    try:
        if isinstance(x, unicode):          # Python2 unicode
            return x.encode("utf-8", "ignore")
        elif isinstance(x, str):            # Python2 bytes
            return x
        else:
            return str(x)
    except Exception:
        return "Okay."


# =====================================================
#  PLACEHOLDERS — implement later
# =====================================================
def handle_song(text):
    print("[SONG] Placeholder | text =", text)
    pass


def handle_animation(text):
    print("[ANIMATION] Placeholder | text =", text)
    pass

def stop_gesture():
    try:
        tts.say("^start(animations/Stand/Gestures/Stop_1) Stop. ^wait(animations/Stand/Gestures/Stop_1)")
    except Exception as e:
        print("Gesture error:", e)

# =====================================================
#  MAIN LOOP
# =====================================================
while True:

    send_request = "Continue"
    print("Sending request ...")
    socket.send(send_request)

    try:
        print("Waiting for message... Press Ctrl+C to cancel.")
        while True:

            events = dict(poller.poll(100))
            if socket in events:

                # =====================================================
                # RECEIVE RAW ZMQ MESSAGE
                # =====================================================
                raw = socket.recv()
                print("Received raw:", raw)

                # Decode to unicode for parsing/printing (safe)
                try:
                    decoded = raw.decode("utf-8", "ignore")
                except Exception:
                    decoded = raw  # already unicode or some other encoding

                decoded = decoded.strip()
                print("Decoded clean message:", decoded)

                # =====================================================
                # PARSE action:response
                # =====================================================
                if ":" in decoded:
                    action, response_text = decoded.split(":", 1)
                    action = action.strip()
                    response_text = response_text.strip()
                else:
                    action = "speech"
                    response_text = decoded.strip()

                print("Action:", action)
                print("Response Text:", response_text)

                # =====================================================
                # ROUTING
                # =====================================================

                if action == "speech":
                    clean_text = response_text.strip()
                    if clean_text == "":
                        clean_text = "Okay."

                    clean_text = nao_str(clean_text)

                    print("[ANIMATED SPEECH] Saying:", clean_text)
                    animated_speech.say("\\rspd=83\\ " + clean_text)


                elif action == "song":
                    handle_song(response_text)

                elif action == "animation":
                    handle_animation(response_text)

                else:
                    clean_text = nao_str(response_text.strip())
                    animated_speech.say(clean_text)

                break
            



                
            """
            
                if action == "speech":
                    clean_text = response_text.strip()
                    if clean_text == "":
                        clean_text = "Okay."

                    # 1) convert to safe ASCII-ish bytes (Python2 str)
                    clean_text = unidecode(clean_text)

                    # 2) ensure NAOqi gets Python2 bytes str, not unicode
                    clean_text = nao_str(clean_text)

                    print("[SPEAK] Saying:", clean_text)
                    tts.say(clean_text)

                elif action == "song":
                    handle_song(response_text)

                elif action == "animation":
                    handle_animation(response_text)

                else:
                    # Fallback to speech
                    clean_text = unidecode(response_text.strip())
                    clean_text = nao_str(clean_text)
                    print("[SPEAK-FALLBACK] Saying:", clean_text)
                    tts.say(clean_text)

                break
                """

    except KeyboardInterrupt:
        print("Cancelled by user.")
        cancel = True

    if cancel:
        break
