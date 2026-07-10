import axios from 'axios';

// Always use the same origin as the page — works on any port (5667, 3000, tunnel, etc.)
// NEVER hardcode localhost:8000
const API_BASE_URL = '';

const api = axios.create({
  baseURL: API_BASE_URL,
  headers: {
    'Content-Type': 'application/json',
  },
});

// Add token to requests if one exists in localStorage (optional auth)
api.interceptors.request.use((config) => {
  const token = localStorage.getItem('penny_token') || localStorage.getItem('token');
  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});

// Auth endpoints
export const login = async (username, password) => {
  const response = await api.post('/login', { username, password });
  return response.data;
};

export const getCurrentUser = async () => {
  const response = await api.get('/me');
  return response.data;
};

// Upload a bank statement (CSV / PDF / ZIP)
export const uploadDocument = async (file) => {
  const token = localStorage.getItem('penny_token') || localStorage.getItem('token');
  const response = await fetch(`/upload?name=${encodeURIComponent(file.name)}`, {
    method: 'POST',
    headers: token ? { 'Authorization': `Bearer ${token}` } : {},
    body: file,
  });
  if (!response.ok) {
    const err = await response.json().catch(() => ({}));
    throw new Error(err.detail || `Upload failed (${response.status})`);
  }
  return response.json();
};

// List uploaded statements
export const listDocuments = async () => {
  const response = await api.get('/documents');
  return response.data;
};

// Ask a question (non-streaming)
export const queryDocuments = async (question, documentNames = null) => {
  const response = await api.post('/query', {
    question,
    document_names: documentNames,
    n_results: 5,
  });
  return response.data;
};

// Ask a question (streaming — token-by-token)
export const queryDocumentsStream = async (question, documentNames, onToken, onDone, onError) => {
  const token = localStorage.getItem('penny_token') || localStorage.getItem('token');

  const response = await fetch('/query', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { 'Authorization': `Bearer ${token}` } : {}),
    },
    body: JSON.stringify({
      question,
      document_names: documentNames,
      n_results: 5,
    }),
  });

  if (!response.ok) {
    throw new Error(`HTTP error: ${response.status}`);
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();

  try {
    let buf = '';
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      buf += decoder.decode(value, { stream: true });
      const lines = buf.split('\n');
      buf = lines.pop(); // keep incomplete last line in buffer

      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const data = JSON.parse(line);
          if (data.type === 'chunk') {
            onToken(data.content);
          } else if (data.type === 'meta') {
            // ignore meta
          } else if (data.type === 'done') {
            if (onDone) onDone(data.sources);
          }
        } catch {
          // also handle SSE "data: ..." format
          if (line.startsWith('data: ')) {
            try {
              const data = JSON.parse(line.slice(6));
              if (data.type === 'token') onToken(data.content);
              else if (data.type === 'done' && onDone) onDone(data.sources);
            } catch { /* ignore */ }
          }
        }
      }
    }
    if (onDone) onDone([]);
  } catch (error) {
    if (onError) onError(error);
    throw error;
  }
};

// Delete a document
export const deleteDocument = async (docName) => {
  const response = await api.delete(`/documents/${docName}`);
  return response.data;
};

export default api;