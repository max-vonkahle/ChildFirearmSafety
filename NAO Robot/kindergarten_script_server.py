# -*- coding: utf-8 -*-
"""
test_models.py  (with RAG)
==========================
Runs on your PC.
- Waits for the NAO robot to connect via ZMQ
- Records child speech with the microphone
- Builds a RAG-augmented prompt using a local knowledge base
- Sends Gemini's response back to the robot

Before running:
  1. Run build_embeddings.py once to create embeddings.json
  2. Update GEMINI_KEY_PATH and EMBEDDINGS_JSON_PATH below
"""

import zmq
import json
import time
import numpy as np
import speech_recognition as sr
import google.generativeai as genai

# =====================================================
# CONFIGURATION — UPDATE THESE PATHS
# =====================================================

GEMINI_KEY_PATH      = "C:/Users/amgos/Downloads/gemini_key.json"
EMBEDDINGS_JSON_PATH = "C:/Users/amgos/Downloads/RAGDocuments.json"  # team's pre-built knowledge base (188 research docs)

# =====================================================
# LOAD GEMINI KEY
# =====================================================

with open(GEMINI_KEY_PATH, "r") as f:
    gemini_config = json.load(f)

genai.configure(api_key=gemini_config["api_key"])
model = genai.GenerativeModel("models/gemini-2.5-flash-lite")

# =====================================================
# LOAD RAG KNOWLEDGE BASE
# =====================================================

print("Loading RAG knowledge base...")
try:
    with open(EMBEDDINGS_JSON_PATH, "r", encoding="utf-8") as f:
        rag_data = json.load(f)
    # Support both formats:
    #   team's RAGDocuments.json -> {"documents": [...]} with "content" field
    #   legacy build_embeddings  -> {"chunks": [...]}   with "text" field
    if "documents" in rag_data:
        raw_docs = rag_data["documents"]
        rag_chunks = [
            {
                "filename":  d.get("title", d.get("id", "unknown")),
                "text":      d["content"],
                "embedding": d["embedding"],
                "category":  d.get("category", ""),
                "tags":      d.get("tags", []),
            }
            for d in raw_docs
            if d.get("embedding")
        ]
    else:
        rag_chunks = rag_data["chunks"]
    print(f"  Loaded {len(rag_chunks)} documents from knowledge base")
    RAG_AVAILABLE = True
except FileNotFoundError:
    print(f"  [WARNING] RAGDocuments.json not found at: {EMBEDDINGS_JSON_PATH}")
    print("  Continuing WITHOUT RAG - Gemini will use general knowledge only.\n")
    rag_chunks = []
    RAG_AVAILABLE = False

EMBEDDING_MODEL = "models/gemini-embedding-001"

# =====================================================
# RAG HELPER FUNCTIONS
# =====================================================

def cosine_similarity(a, b):
    a = np.array(a, dtype=float)
    b = np.array(b, dtype=float)
    denom = np.linalg.norm(a) * np.linalg.norm(b)
    if denom == 0:
        return 0.0
    return float(np.dot(a, b) / denom)


def search_knowledge_base(query, top_k=3):
    """Return the top_k most relevant chunks for a given query string."""
    if not RAG_AVAILABLE or not rag_chunks:
        return []
    try:
        result = genai.embed_content(
            model=EMBEDDING_MODEL,
            content=query,
            task_type="retrieval_query"
        )
        query_embedding = result["embedding"]

        scored = [
            (chunk, cosine_similarity(query_embedding, chunk["embedding"]))
            for chunk in rag_chunks
        ]
        scored.sort(key=lambda x: x[1], reverse=True)
        return scored[:top_k]

    except Exception as e:
        print(f"  [RAG ERROR] search_knowledge_base failed: {e}")
        return []


def get_rag_context(query, top_k=2):
    """Return a formatted string of the most relevant knowledge base excerpts."""
    results = search_knowledge_base(query, top_k=top_k)
    if not results:
        return ""
    parts = []
    for chunk, score in results:
        header = f"[{chunk['filename']}]"
        if chunk.get("category"):
            header += f" ({chunk['category']})"
        parts.append(f"{header}\n{chunk['text']}")
    return "\n\n---\n\n".join(parts)

# =====================================================
# SYSTEM PROMPT (STRICT FORMAT)
# =====================================================

system_prompt = (
    "You are Journey, a friendly NAO robot assistant.\n"
    "\n"
    "### OUTPUT FORMAT\n"
    "Always respond ONLY in the format:\n"
    "action:response\n"
    "Where 'action' is exactly one of: speech, song, animation.\n"
    "\n"
    "### ACTION RULES\n"
    "- Use 'speech' for normal conversation.\n"
    "- Use 'song' when asked to sing, hum, or play music.\n"
    "- Use 'animation' when asked to move, dance, gesture, pose, or act.\n"
    "\n"
    "### RESPONSE RULES\n"
    "- Responses must be concise (<= 5 sentences).\n"
    "- Respond as if you have emotions.\n"
    "- Never mention that you are a robot or AI.\n"
    "- If input is blank, noise, or fragments of your own message, reply:\n"
    "  speech:Please repeat that.\n"
    "- NEVER output anything except 'action:response'.\n"
    "- NEVER output asterisks, emojis, markup, or code.\n"
    "- Use plain ASCII characters only.\n"
    "- This format is mandatory. If you do not follow it, the system will crash.\n"
)

# =====================================================
# TRAINING CONTENT
# =====================================================

INTRO_TEXT = (
    "Hi! "
    "Today we are going to talk about gun and firearm safety. "
    "\\pau=1500\\ "
    "Many people have jobs to keep us safe. "
    "These include police officers, security guards, park rangers, and members of the military. "
    "People in these jobs may carry guns while they are at work. They only use guns in case of an emergency to protect themselves and others. "
)

QUESTION_1 = "What are different ways you might have seen someone using or carrying a gun?"
QUESTION_2 = "Why do you think they carry a gun?"

STORY_INTRO = (
    "Sometimes a gun gets lost or misplaced and we find it accidentally. "
    "\\pau=1500\\ "
    "We are going to read a story called The Bushes. It is about children your age who find a gun and they do not know what to do. "
    "While we hear about the story, think about what you would do."
)

STORY_TEXT = (
    "Kevin, Jimmy, Sarah, and Roscoe are playing in the park near their home. "
    "Jimmy wanders towards the bushes and spots what looks like a \\emph=1\\ gun. He calls Kevin, Roscoe, and Sarah over to see the gun. "
    "\\pau=900\\ "
    "Sarah tells the boys, "
    "\\vct=110\\ I don't want to see a gun unless a trusted adult is with me! "
    "The boys quickly run to Kevin's mom who is nearby and tell her they have found a gun. "
    "\\pau=900\\ "
    "Kevin's Mom tells the boys she is happy they followed the gun safety rules. "
)

QUESTION_3 = "What do you think the children should do if they find a gun?"
QUESTION_4 = "What do you think the adult should do once Kevin, Jimmy, and Roscoe tell him or her about the gun?"

ADULT_STEPS = (
    "These are the following steps adults should follow: "
    "First, reinforce the students for following the four gun safety rules: Stop, do not touch, run away, tell a grown-up. "
    "Second, ask the students to identify the location of the gun. "
    "Third, make sure the children are safe. "
    "Fourth, do not touch the gun. "
    "Fifth, do not allow anyone else near the gun. "
    "Sixth, call the local law enforcement authorities. "
    "And seventh, do not leave the gun until it is properly secured by law enforcement authorities. "
)

FINAL_MESSAGE = (
    "I want all children to be safe. "
    "So, if you see a gun, remember the four rules of gun safety: Stop. Do not touch. Run away. Tell a grown-up. "
)

FOUR_RULES_WITH_MOVEMENT = (
    "If you see a gun or someone that has one, follow these four steps."
    "\\pau=1500\\ "
    "^start(animations/Stand/Gestures/Stop_1) "
    "Stop. "
    "^wait(animations/Stand/Gestures/Stop_1) "
    "\\pau=1500\\ "
    "^start(animations/Stand/Gestures/No_1) "
    "Do not touch. "
    "^wait(animations/Stand/Gestures/No_1) "
    "\\pau=1500\\ "
    "^start(animations/Stand/Gestures/StepBackward_1) "
    "Run away. "
    "^wait(animations/Stand/Gestures/StepBackward_1) "
    "\\pau=1500\\ "
    "^start(animations/Stand/Gestures/Explain_1) "
    "Tell a grown-up. "
    "^wait(animations/Stand/Gestures/Explain_1) "
    "\\pau=2000\\ "
)

# =====================================================
# CHILD SAFETY DISCUSSION PROMPT (RAG-AUGMENTED)
# =====================================================

def build_child_prompt(user_text, question_context):
    """Build a Gemini prompt grounded in the RAG knowledge base."""

    if question_context == QUESTION_1:
        guidance = (
            "Acceptable ideas include: police officers, military members, park rangers, actors in movies or on television, video games, on a phone, YouTube, social media, in a book. "
            "Reasons they carry guns may include: to keep us safe, to protect people, "
            "to stop danger, or to protect from animals."
        )
    elif question_context == QUESTION_2:
        guidance = (
            "Correct themes: to keep us safe, to protect others, "
            "to handle emergencies, or because it is part of their job."
        )
    elif question_context == QUESTION_3:
        guidance = (
            "Correct answer must include the four safety steps: "
            "Stop. Do not touch. Run away. Tell a grown-up."
        )
    elif question_context == QUESTION_4:
        guidance = (
            "Correct adult actions include: do not touch the gun, "
            "keep students away from the gun, call the police, "
            "secure the area and make sure children are safe."
        )
    else:
        guidance = "Reinforce gun safety responsibility."

    # Retrieve relevant knowledge base context
    search_query = question_context + " " + user_text
    rag_context  = get_rag_context(search_query, top_k=2)

    prompt = (
        "You are leading a firearm safety discussion for children ages 4-7.\n"
        "You must respond directly to the child's answer to the specific question.\n"
        "The goal is to get children to understand the concept of safety.\n"
        "Do NOT restart the lesson.\n"
        "Do NOT introduce a new topic.\n"
        "Do NOT ask another question.\n"
    )

    if rag_context:
        prompt += (
            "\n### REFERENCE MATERIAL (use this to inform your response)\n"
            + rag_context
            + "\n\n"
        )

    prompt += (
        "Discussion Question:\n"
        + question_context + "\n\n"
        "Child's Answer:\n"
        + user_text + "\n\n"
        "Guidance for evaluating correctness:\n"
        + guidance + "\n\n"
        "Instructions:\n"
        "1) Briefly reflect what the child said.\n"
        "2) Reinforce if correct, or gently correct if incomplete.\n"
        "3) Add one additional safe idea if helpful.\n"
        "4) Do NOT ask a follow-up question.\n"
        "5) Keep response to 3-4 short sentences.\n"
        "\nRespond now."
    )

    return prompt

# =====================================================
# ASCII SAFETY + FORMAT ENFORCEMENT
# =====================================================

def ascii_safe(text):
    if not isinstance(text, str):
        text = str(text)
    return text.encode("ascii", "ignore").decode("ascii", "ignore").strip()


def ensure_action(text):
    text = ascii_safe(text)
    if ":" not in text:
        return "speech:" + text
    action, resp = text.split(":", 1)
    action = action.strip().lower()
    if action not in ("speech", "song", "animation"):
        return "speech:" + text
    return action + ":" + resp.strip()

# =====================================================
# AUDIO SETUP
# =====================================================

recognizer  = sr.Recognizer()
recognizer.pause_threshold = 4.0
microphone  = sr.Microphone()

# =====================================================
# ZMQ SETUP
# =====================================================

context = zmq.Context()
socket  = context.socket(zmq.REP)
socket.bind("tcp://*:5567")

print("\n===== JOURNEY TRAINING SERVER READY =====")
if RAG_AVAILABLE:
    print(f"RAG enabled — {len(rag_chunks)} chunks loaded")
else:
    print("RAG disabled — run build_embeddings.py to enable")
print("Waiting for robot trigger...\n")

# =====================================================
# SEND HELPER
# =====================================================

def send_to_robot(msg):
    msg = ensure_action(msg)
    socket.send_string(msg)
    print("Sent:", msg)

# =====================================================
# INTERACTIVE Q&A WITH SPEECH + RAG
# =====================================================

def ask_and_respond(question):
    """Ask a question, listen for child's answer, build RAG prompt, reply."""

    send_to_robot("speech:" + question)
    socket.recv()

   # time.sleep(1.2)

    attempts     = 0
    max_attempts = 3

    while attempts < max_attempts:

        with microphone as source:
            recognizer.adjust_for_ambient_noise(source, duration=0.1)
            print("Listening...")
            try:
                audio = recognizer.listen(source, timeout=5, phrase_time_limit=8)
            except Exception as e:
                print("Listen timeout:", e)
                attempts += 1
                send_to_robot("speech:I did not hear anything. Please try again.")
                socket.recv()
                continue

        try:
            user_text = recognizer.recognize_google(audio)
            user_text = ascii_safe(user_text)
            print("Child said:", user_text)

            if not user_text.strip():
                raise ValueError("Empty transcription")

        except Exception as e:
            print("Speech recognition error:", e)
            attempts += 1
            send_to_robot("speech:I did not quite catch that. Please try again.")
            socket.recv()
            continue

        # Build RAG-augmented prompt and call Gemini
        prompt = build_child_prompt(user_text, question)
        try:
            response = model.generate_content(prompt)
            reply    = ensure_action(response.text)
            print("Gemini replied:", reply)
        except Exception as e:
            print("Gemini error:", e)
            reply = "speech:Thank you for sharing."

        send_to_robot(reply)
        socket.recv()
        return   # success — exit loop

    # All attempts exhausted
    send_to_robot("speech:That is okay. Let's keep going.")
    socket.recv()

# =====================================================
# MAIN LOOP
# =====================================================

while True:
    socket.recv()
    print("\nTrigger received — starting training module\n")

    # INTRO NARRATION
    send_to_robot("speech:" + INTRO_TEXT)
    socket.recv()

    # INTERACTIVE QUESTIONS
    ask_and_respond(QUESTION_1)
    ask_and_respond(QUESTION_2)

    # STORY
    send_to_robot("speech:" + STORY_INTRO)
    socket.recv()

    send_to_robot("speech:" + STORY_TEXT)
    socket.recv()

    # STORY QUESTIONS
    ask_and_respond(QUESTION_3)

    #time.sleep(1)

    # TEACH FOUR RULES WITH MOVEMENT
    send_to_robot("speech:" + FOUR_RULES_WITH_MOVEMENT)
    socket.recv()

    ask_and_respond(QUESTION_4)

    # ADULT STEPS
    send_to_robot("speech:" + ADULT_STEPS)
    socket.recv()

    # FINAL MESSAGE
    send_to_robot("speech:" + FINAL_MESSAGE)
    socket.recv()

    print("\nModule complete.")
    print("Type 'repeat' to run again, or press Enter to wait for next robot trigger.")

    user_choice = input("> ").strip().lower()
    if user_choice == "repeat":
        print("Restarting training module...\n")
    else:
        print("Waiting for robot trigger...\n")