import { createRouter, createWebHistory } from 'vue-router'
import NetworkMetricHealthView from '../views/NetworkMetricHealthView.vue'
import MonitoredServicesView from '../views/MonitoredServicesView.vue'
import NodesView from '../views/NodesView.vue'
import NodeDetailsView from '../views/NodeDetailsView.vue'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/network-metrics0and-health',
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
      path: '/nodes',
      name: 'nodes',
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
