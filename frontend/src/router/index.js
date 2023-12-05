import { createRouter, createWebHistory } from 'vue-router'
import HomeView from '../views/HomeView.vue'
import AboutView from '../views/AboutView.vue'
import NetworkMetricHealthView from '../views/NetworkMetricHealthView.vue'
import MonitoredServicesView from '../views/MonitoredServicesView.vue'
import NodesView from '../views/NodesView.vue'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/',
      name: 'home',
      component: HomeView
    },
    {
      path: '/about',
      name: 'about',
      component: AboutView
      // route level code-splitting
      // this generates a separate chunk (About.[hash].js) for this route
      // which is lazy-loaded when the route is visited.
      // component: () => import('../views/AboutView.vue')
    },
    {
      path: '/network-metrics0and-health',
      name: 'networkMetricsAndhealth',
      component: NetworkMetricHealthView
    },
    {
      path: '/monitored-services',
      name: 'monitoredServices',
      component: MonitoredServicesView
    },
    {
      path: '/nodes',
      name: 'nodes',
      component: NodesView
    },
  ]
})

export default router
