import { createRouter, createWebHistory } from 'vue-router'
import HomeView from '../views/HomeView.vue'
import NetworkMetricHealthView from '../views/NetworkMetricHealthView.vue'
import MonitoredServicesView from '../views/MonitoredServicesView.vue'
import NodesView from '../views/NodesView.vue'
import NodeDetailsView from '../views/NodeDetailsView.vue'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/',
      name: 'home',
      component: HomeView
            // route level code-splitting
      // this generates a separate chunk (About.[hash].js) for this route
      // which is lazy-loaded when the route is visited.
      // component: () => import('../views/AboutView.vue')
    },
    {
      path: '/index',
      name: 'index',
      component: HomeView
            // route level code-splitting
      // this generates a separate chunk (About.[hash].js) for this route
      // which is lazy-loaded when the route is visited.
      // component: () => import('../views/AboutView.vue')
    },
    {
      path: '/network-metrics-and-health',
      name: 'networkMetricsAndhealth',
      component: NetworkMetricHealthView
            // route level code-splitting
      // this generates a separate chunk (About.[hash].js) for this route
      // which is lazy-loaded when the route is visited.
      // component: () => import('../views/AboutView.vue')
    },
    {
      path: '/monitored-services',
      name: 'monitoredServices',
      component: MonitoredServicesView
    },
    {
      path: '/nodesList',
      name: 'nodesList',
      component: NodesView
    },
    {
      path: '/nodes/:uuid',
      name: 'nodeDetails',
      component: NodeDetailsView
    },
  ]
})

export default router
