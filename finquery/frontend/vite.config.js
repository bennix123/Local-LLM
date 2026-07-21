import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/api': { target: 'http://localhost:5667', changeOrigin: true },
      '/login': { target: 'http://localhost:5667', changeOrigin: true },
      '/register': { target: 'http://localhost:5667', changeOrigin: true },
      '/me': { target: 'http://localhost:5667', changeOrigin: true },
      '/upload': { target: 'http://localhost:5667', changeOrigin: true },
      '/documents': { target: 'http://localhost:5667', changeOrigin: true },
      '/document': { target: 'http://localhost:5667', changeOrigin: true },
      '/query': { target: 'http://localhost:5667', changeOrigin: true },
      '/models': { target: 'http://localhost:5667', changeOrigin: true },
      '/classic': { target: 'http://localhost:5667', changeOrigin: true },
      '/chat': { target: 'http://localhost:5667', changeOrigin: true },
      '/dashboard': { target: 'http://localhost:5667', changeOrigin: true },
      '/status': { target: 'http://localhost:5667', changeOrigin: true },
    },
  },
})