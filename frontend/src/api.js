import axios from 'axios'

const api = axios.create({
  baseURL: '/api',
  timeout: 5000,
})

export const fetchHello = () => api.get('/hello').then((r) => r.data)
export const fetchNotes = () => api.get('/notes').then((r) => r.data)
export const createNote = (content) => api.post('/notes', { content }).then((r) => r.data)
export const incrementCounter = () => api.get('/counter').then((r) => r.data)
