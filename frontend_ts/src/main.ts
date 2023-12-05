import './assets/main.css'

import { createApp } from 'vue'
import { createPinia } from 'pinia'

import App from './App.vue'
import router from './router'

window.onload = () => {
    console.log("ONLOAD");
};
const app = createApp(App)
console.log('test')
app.use(createPinia())
app.use(router)

app.mount('#app')
