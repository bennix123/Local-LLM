
from __future__ import annotations

import os
import sqlite3
import hashlib
import textwrap
from pathlib import Path
from typing import List, Tuple

import streamlit as st
import pandas as pd
from pypdf import PdfReader
import ollama

# --------------------------------------------------------------
# Configuration constants
# --------------------------------------------------------------
DB_PATH = Path("document_agent.db")
MAX_FILE_SIZE = 1 * 1024 * 1024          # 1 MiB
CHUNK_SIZE = 1000                        # approx. characters per chunk
CHUNK_OVERLAP = 200                      # characters overlapping between chunks
DEFAULT_MODEL = "llama3.2:3b"              # fallback if user has not changed it
MAX_RESULTS = 5                          # number of FTS hits per query

def get_connection() -> sqlite3.Connection:
    """Return a connection with the required FTS5 extension enabled."""
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL;")
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    """Create (or recreate) the FTS5 virtual table."""
    cur = conn.cursor()
    # Drop existing virtual table and its content (if any)
    cur.execute("DROP TABLE IF EXISTS documents_fts;")
    # Create a new FTS5 table with the needed columns
    cur.execute(
        """
        CREATE VIRTUAL TABLE documents_fts USING fts5(
            file_name,
            chunk_index,
            content
        );
        """
    )
    conn.commit()

def clear_db(conn: sqlite3.Connection) -> None:
    """Remove all rows – used when a new file is uploaded."""
    cur = conn.cursor()
    cur.execute("DELETE FROM documents_fts;")
    conn.commit()


def insert_chunk(
    conn: sqlite3.Connection, file_name: str, chunk_index: int, content: str
) -> None:
    """Insert a single text chunk into the FTS table."""
    conn.execute(
        "INSERT INTO documents_fts (file_name, chunk_index, content) VALUES (?,?,?);",
        (file_name, chunk_index, content),
    )


def search_chunks(conn: sqlite3.Connection, query: str) -> List[Tuple[int, str]]:
    """
    Return up to MAX_RESULTS matching chunks.
    The query is passed directly to the FTS5 MATCH operator.
    """
    cur = conn.execute(
        """
        SELECT rowid, content
        FROM documents_fts
        WHERE documents_fts MATCH ?
        ORDER BY rank
        LIMIT ?;
        """,
        (query, MAX_RESULTS),
    )
    return [(rowid, content) for rowid, content in cur.fetchall()]

def chunk_text(text: str) -> List[str]:
    """Break `text` into overlapping chunks (≈CHUNK_SIZE chars)."""
    chunks = []
    start = 0
    while start < len(text):
        end = start + CHUNK_SIZE
        chunk = text[start:end]
        chunks.append(chunk.strip())
        start = end - CHUNK_OVERLAP  # overlap for context continuity
    return chunks


def parse_pdf(file_path: Path) -> List[str]:
    """Extract raw text from a PDF and return a list of chunks."""
    reader = PdfReader(str(file_path))
    full_text = ""
    for page_num, page in enumerate(reader.pages, start=1):
        page_text = page.extract_text() or ""
        if page_text:
            full_text += f"\n--- Page {page_num} ---\n{page_text}"
    return chunk_text(full_text)


def parse_csv(file_path: Path) -> List[str]:
    """Read a CSV into pandas, then turn rows into readable sentences."""
    df = pd.read_csv(file_path, dtype=str, keep_default_na=False)
    rows = []
    for idx, row in df.iterrows():
        parts = [f"{col} is {val}" for col, val in row.items()]
        rows.append(f"Row {idx + 1}: " + ", ".join(parts) + ".")
    # Join rows and chunk the resulting string (keeps context across rows)
    combined = "\n".join(rows)
    return chunk_text(combined)


def ingest_file(uploaded_file: "UploadedFile", conn: sqlite3.Connection) -> str:
    """
    Store the uploaded file's chunks into the DB.
    Returns a short status message.
    """
    # Write upload to a temporary location (same folder as DB)
    temp_path = Path("uploads") / uploaded_file.name
    temp_path.parent.mkdir(parents=True, exist_ok=True)
    with open(temp_path, "wb") as f:
        f.write(uploaded_file.getbuffer())

    # Clear old data before new ingestion
    clear_db(conn)

    # Choose parser based on extension
    ext = uploaded_file.name.lower().split(".")[-1]
    if ext == "pdf":
        chunks = parse_pdf(temp_path)
    elif ext == "csv":
        chunks = parse_csv(temp_path)
    else:
        raise ValueError("Unsupported file type.")

    # Insert all chunks in a single transaction
    with conn:
        for idx, chunk in enumerate(chunks):
            insert_chunk(conn, uploaded_file.name, idx, chunk)

    return f"Ingested **{uploaded_file.name}** – {len(chunks)} chunks stored."


# --------------------------------------------------------------
# Ollama interaction
# --------------------------------------------------------------
def build_prompt(user_query: str, context_chunks: List[Tuple[int, str]]) -> str:
    """
    Create a prompt that includes the retrieved context.
    The LLM will see:
      • The user question
      • Up to MAX_RESULTS relevant text blocks
    """
    context_text = "\n\n".join(
        f"[Context {i+1}]\n{content}" for i, (_, content) in enumerate(context_chunks)
    )
    prompt = textwrap.dedent(
        f"""
        You are a helpful assistant that works with the content of uploaded documents.
        Use the provided context to answer the user's question as accurately as possible.
        If the answer cannot be derived from the context, say so politely.

        ### User question
        {user_query}

        ### Context
        {context_text}
        """
    )
    return prompt


def stream_llm_response(prompt: str, model: str = DEFAULT_MODEL):
    """
    Calls `ollama.chat` with streaming enabled.
    Yields the response chunks to be displayed by Streamlit.
    """
    try:
        for part in ollama.chat(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            stream=True,
        ):
            content = part.get("message", {}).get("content", "")
            if content:
                yield content
    except Exception as e:
        raise RuntimeError(f"Ollama request failed: {e}")


# --------------------------------------------------------------
# Streamlit UI
# --------------------------------------------------------------
def main() -> None:
    st.set_page_config(page_title="📄 Document RAG with Ollama", layout="wide")
    st.title("📚 Document:Based Chat with a Local LLM")

    # Initialise DB connection (cached for the session)
    if "db_conn" not in st.session_state:
        st.session_state.db_conn = get_connection()
        init_db(st.session_state.db_conn)

    # Sidebar – file upload & DB reset
    with st.sidebar:
        st.header("📂 Document Management")
        uploaded = st.file_uploader(
            "Upload a PDF or CSV (max 1 MiB)",
            type=["pdf", "csv"],
            accept_multiple_files=False,
            help="Only the most recent file is kept in the database.",
        )
        if uploaded:
            if uploaded.size > MAX_FILE_SIZE:
                st.error("❗ File exceeds the 1 MiB size limit.")
            else:
                with st.spinner("Parsing and indexing…"):
                    try:
                        status_msg = ingest_file(uploaded, st.session_state.db_conn)
                        st.success(status_msg)
                    except Exception as exc:
                        st.error(f"❌ Failed to ingest file: {exc}")

        if st.button("Reset Database", use_container_width=True):
            clear_db(st.session_state.db_conn)
            st.success("🗑️ Database cleared.")

        st.markdown("---")
        st.caption(
            "💡 Ensure Ollama is running and the desired model is pulled. "
            f"Default model: **{DEFAULT_MODEL}**"
        )

    # Initialise chat history in session_state
    if "messages" not in st.session_state:
        st.session_state.messages = []  # List[dict] with keys: role, content
        st.session_state.last_ai_message = ""  # Helper for streaming

    # Display chat messages
    for msg in st.session_state.messages:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])

    # Chat input
    if prompt := st.chat_input("Ask a question about the uploaded document"):
        # Append user message to history
        st.session_state.messages.append({"role": "user", "content": prompt})
        with st.chat_message("user"):
            st.markdown(prompt)

        # Retrieve relevant chunks and generate response
        try:
            conn = st.session_state.db_conn
            relevant = search_chunks(conn, prompt)
            if not relevant:
                context_prompt = "No relevant document fragments were found."
            else:
                context_prompt = build_prompt(prompt, relevant)

            # Stream response from Ollama inside the chat message container
            with st.chat_message("assistant"):
                response_generator = stream_llm_response(context_prompt, model=DEFAULT_MODEL)
                full_response = st.write_stream(response_generator)

            # Finalise message in history
            st.session_state.messages.append(
                {"role": "assistant", "content": full_response}
            )
        except Exception as err:
            error_msg = f"⚠️ Error: {err}"
            st.session_state.messages.append({"role": "assistant", "content": error_msg})
            with st.chat_message("assistant"):
                st.error(error_msg)


if __name__ == "__main__":
    main()