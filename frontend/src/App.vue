<script setup>
import { RouterLink, RouterView } from 'vue-router'
import HelloWorld from './components/HelloWorld.vue'
import Menu from './components/Menu.vue'
import 'vite/modulepreload-polyfill'
</script>

<template>
  <div class="container">
    <div class="row">
      <Menu></Menu>
    </div>
  </div>

  <RouterView />
</template>

