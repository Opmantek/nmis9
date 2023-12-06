import './assets/main.css'

import { createApp } from 'vue'
import { createPinia } from 'pinia'

import App from './App.vue'
import router from './router'

window.addEventListener('load', (event) => {
console.log('OnLoad');
  });




const app = createApp(App)
console.log('App');
app.use(createPinia())
app.use(router)

app.mount('#app')
