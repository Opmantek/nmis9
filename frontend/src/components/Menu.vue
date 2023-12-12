<template>
    <nav class="navbar navbar-default navbar-expand-lg navbar-dark mb-3">
  <div class="container-fluid">
    <a class="navbar-brand" href="/">NMIS</a>
    <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNavDropdown" aria-controls="navbarNavDropdown" aria-expanded="false" aria-label="Toggle navigation">
      <span class="navbar-toggler-icon"></span>
    </button>
    <div class="collapse navbar-collapse" id="navbarNavDropdown">
        <ul class="navbar-nav">
            <!-- <li class="nav-item">
              <RouterLink class="nav-link" to="/nodes">Nodes</RouterLink>
            </li> -->
            <li class="nav-item dropdown">
                <a class="nav-link dropdown-toggle" href="/" id="network-status" role="button" data-bs-toggle="dropdown" aria-expanded="false">
                Network Status
                </a>
                <ul class="dropdown-menu" aria-labelledby="network-status">
                    <li><RouterLink class="dropdown-item" to="/network-metrics-and-health">Network Metrics & Health</RouterLink></li>
                    <li><RouterLink class="dropdown-item" to="/">Current Events</RouterLink></li>
                    <li><RouterLink class="dropdown-item" to="/monitored-services">Monitored Services</RouterLink></li>
                </ul>
            </li>
        </ul>
      <ul class="navbar-nav navbar-right ms-auto">
        
        <li class="nav-item dropdown">
          <a class="nav-link dropdown-toggle" href="#" id="navbarDropdownMenuLink" role="button" data-bs-toggle="dropdown" aria-expanded="false">
            Modules
          </a>
          <ul class="dropdown-menu" aria-labelledby="navbarDropdownMenuLink" v-if="apps_available.length">
            <li v-for="app in apps_available"><a class="dropdown-item" :href="app.url">{{app.name}}</a></li>
          </ul>
        </li>

        <li class="nav-item dropdown">
          <a class="nav-link dropdown-toggle" href="#" id="navbarDropdownUserLink" role="button" data-bs-toggle="dropdown" aria-expanded="false">
            User
          </a>
          <ul class="dropdown-menu" aria-labelledby="navbarDropdownUserLink" v-if="apps_available.length">
            <li><a class="dropdown-item" href="/logout">Logout</a></li>
          </ul>
        </li>
      </ul>
    </div>
  </div>
</nav>

</template>

<script>
import { RouterLink, RouterView } from 'vue-router';
import axios from 'axios';

export default {
  data() {
    return{
        apps_available:[]
    }
  },
  created() {
    axios.get('/api/v1/modules')
    .then(response => {
      this.apps_available = response.data;
    })
  }
}
</script>

<style scoped>
   .navbar .navbar-brand {
        color: #ffffff; 
    }
    .navbar-nav .nav-link{
        color: #ffffff; 
    }
</style>