<script setup>
import { ref, onMounted } from 'vue'
import { fetchHello, fetchNotes, createNote, incrementCounter } from './api.js'

const hello = ref(null)
const helloError = ref(null)
const notes = ref([])
const noteInput = ref('')
const counter = ref(null)
const counterError = ref(null)

const loadHello = async () => {
  helloError.value = null
  try {
    hello.value = await fetchHello()
  } catch (e) {
    helloError.value = e.message
  }
}

const loadNotes = async () => {
  try {
    notes.value = await fetchNotes()
  } catch (e) {
    notes.value = []
  }
}

const addNote = async () => {
  if (!noteInput.value.trim()) return
  await createNote(noteInput.value.trim())
  noteInput.value = ''
  await loadNotes()
}

const bump = async () => {
  counterError.value = null
  try {
    const data = await incrementCounter()
    counter.value = data.counter
  } catch (e) {
    counterError.value = e.message
  }
}

onMounted(() => {
  loadHello()
  loadNotes()
})
</script>

<template>
  <main class="app">
    <h1>awsStudy PoC</h1>

    <section class="card">
      <h2>1. Hello (ALB &rarr; ECS &rarr; Backend)</h2>
      <button @click="loadHello">호출</button>
      <pre v-if="hello">{{ JSON.stringify(hello, null, 2) }}</pre>
      <p v-if="helloError" class="error">{{ helloError }}</p>
    </section>

    <section class="card">
      <h2>2. Notes (PostgreSQL CRUD)</h2>
      <form @submit.prevent="addNote">
        <input v-model="noteInput" placeholder="메모 내용" />
        <button type="submit">추가</button>
      </form>
      <ul>
        <li v-for="n in notes" :key="n.id">
          <strong>#{{ n.id }}</strong> {{ n.content }}
          <span class="ts">{{ n.createdAt }}</span>
        </li>
      </ul>
      <p v-if="!notes.length" class="muted">아직 메모 없음</p>
    </section>

    <section class="card">
      <h2>3. Counter (Redis INCR)</h2>
      <button @click="bump">+1</button>
      <p>현재 카운터: <strong>{{ counter ?? '-' }}</strong></p>
      <p v-if="counterError" class="error">{{ counterError }}</p>
    </section>
  </main>
</template>

<style>
body { margin: 0; font-family: system-ui, -apple-system, sans-serif; background: #0f172a; color: #e2e8f0; }
.app { max-width: 720px; margin: 0 auto; padding: 2rem 1.25rem; }
h1 { margin: 0 0 1.5rem; font-size: 1.75rem; }
h2 { margin: 0 0 0.75rem; font-size: 1.1rem; color: #94a3b8; }
.card { background: #1e293b; border: 1px solid #334155; border-radius: 8px; padding: 1.25rem; margin-bottom: 1rem; }
button { background: #38bdf8; color: #0f172a; border: 0; padding: 0.5rem 1rem; border-radius: 4px; cursor: pointer; font-weight: 600; }
button:hover { background: #7dd3fc; }
input { flex: 1; padding: 0.5rem; border-radius: 4px; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; }
form { display: flex; gap: 0.5rem; margin-bottom: 0.75rem; }
pre { background: #0f172a; padding: 0.75rem; border-radius: 4px; overflow-x: auto; font-size: 0.85rem; }
ul { list-style: none; padding: 0; margin: 0; }
li { padding: 0.5rem 0; border-bottom: 1px solid #334155; }
li:last-child { border-bottom: 0; }
.ts { color: #64748b; font-size: 0.8rem; margin-left: 0.5rem; }
.error { color: #f87171; }
.muted { color: #64748b; }
</style>
