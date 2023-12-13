<template>
    <div class="container-fluid">
        <div class="row">
          <div class="col">
            <div class="card">
              <div class="card-header">
                <div class="card-title" v-if="!isLoading">
                  {{  nodeData.name }}
                </div>
                <div v-else>
                    Loading...
                </div>
              </div>
              <div class="card-body">
                <div class="row g-0">
                  <div class="col-8">
                    <table class="table table-bordered" v-if="!isLoading">
                      <tbody>
                        <tr v-for="dataColumn in nodeDataColumns" :key="dataColumn">
                          <td> {{ dataColumn.label }} </td>
                          <td v-if="dataColumn.type == 'timeCell'"> {{ new Date(GetPropertyValue(dataColumn.name) * 1000) }} </td>
                          <td v-else> {{  GetPropertyValue(dataColumn.name) }}</td>

                        </tr>
                      </tbody>
                    </table>
                  </div>
                  <div class="col-4">
                    <table class="table table-bordered" v-if="!isLoading">
                      <tbody>
                        <td>
                          graph cell
                        </td>
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>
  
            </div>
          </div>
        </div>
        
    </div>
</template>

<script>
import axios from 'axios';
export default {

    data() {
      return {
        isLoading: false,
        nodeData : {},
        nodeDataColumns: [
          { "name": "nodestatus",
            "label": "Node Status",
          },
          {
            "name": "sysName",
            "label": "sysName"
          },
          {
            "name": "host",
            "label": "IP Address"
          },
          {
            "name": "host_backup",
            "label": "Backup IP Address"
          },
          { "name": "ip_protocol",
            "label": "IP Protocol",
          },

          { "name": "group",
            "label": "Group",
          },
          { "name": "customer",
            "label": "Customer",

          },
          { "name": "location",
            "label": "Location",
          },
          { "name": "businessService",
            "label": "Business Service",
          },
          { "name": "serviceStatus",
            "label":  "Service Status",
          },
          { "name": "notes",
            "label":  "Notes",
          },
          { "name": "nodeType",
            "label": "Type",
          },
          { "name": "model",
            "label": "Model",
          },
          { "name": "polling_policy",
            "label": "Polling Policy",
          },
          { "name": "sysUpTime",
            "label": "Sys Up Time",
          },
          { "name": "sysLocation",
            "label": "Location",
          },
          { "name": "sysContact",
            "label": "Contact",
          },
          { "name": "sysDescr",
            "label": "Description",
          },
          { "name": "ifNumber",
            "label": "Interfaces",
          },
          { "name": "ping_successful",
            "label": "Last Ping",
            "type": "timeCell"
          },
          { "name": "catchall.data.nodeType",
            "label": "Last Collect",
          },
          { "name": "last_update",
            "label": "Last Update",
            "type": "timeCell"
          },
          { "name": "nodeVendor",
            "label": "Vendor"
          },
          { "name": "sysObjectName",
            "label": "Object Name"
          },
          { "name": "roleType",
            "label": "Role"
          },
          { "name": "netType",
            "label": "Net"
          },
          { "name": "hrSystemProcesses",
            "label": "System Processes"
          },
          { "name": "snmpUpTime",
            "label": "SNMP Uptime"
          },
          { "name": "tcpCurrEstab",
            "label": "TCP Established Sessions"
          },
        ]


      }
    },
    computed: {
      uuid() {
        return this.$route.params.uuid
      },
    },
    created() {
      this.isLoading = true;
      axios.get('/api/v1/nodes/'+this.uuid)
      .then(response => {
        console.log('response: ', response);
        this.nodeData = response.data;
        this.isLoading = false;
      })
    },
    methods: {
      GetPropertyValue(dataToRetrieve) {
        return dataToRetrieve
          .split('.') // split string based on `.`
          .reduce(function(o, k) {
            return o && o[k]; // get inner property if `o` is defined else get `o` and return
          }, this.nodeData) // set initial value as object
      }
    }
}
</script>