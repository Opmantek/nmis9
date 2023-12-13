<template>
    <div class="container-fluid">
        <div class="row">
          <div class="col">
            <div class="card">
              <div class="card-header">
                <div class="card-title">
                  {{  uuid }}
                </div>
              </div>
              <div class="card-body">
                <table class="table" v-if="!isLoading">
                <tbody>
                  <tr v-for="dataColumn in nodeDataColumns" :key="dataColumn.name">
                    <td> {{ dataColumn.label }} -- {{ dataColumn.name }}</td>
                    <td> {{  GetPropertyValue(dataColumn.name)}}</td>

                  </tr>
                </tbody>
              </table>
              </div>
  
            </div>
          </div>
        </div>
        
    </div>
</template>

<script>
import axios from 'axios';
import testData from './test.json';
export default {

    data() {
      return {
        isLoading: false,
        testData,
        data : JSON.stringify(testData),
        nodeDataColumns: [
          { "name": "nodes.uuid",
            "label": "Node UUID",
            "cell": "String",
            "renderable": 0,
            "editable": false
          },
          { "name": "name",
            "label": "Name",
            "cell": "NodeLink",
            "renderable": 1,
            "comment": "must be present for NodeLinkCell to work on any column, use 'renderable': 0 to hide",
            "search" : "iregex",
            "editable": false
          },
          { "name": "nodes.configuration.host",
            "label": "Host",
            "cell": "FilterString",
            "search" : "iregex",
            "editable": false,
            "headerCell": "filter"
          },
          { "name": "catchall.data.nodestatus",
            "label": "Node Status",
            "cell": "NodeStatus",
            "editable": false
          },
          { "name": "nodes.configuration.group",
            "label": "Group",
            "cell": "FilterString",
            "search" : "iregex",
            "editable": false,
            "headerCell": "filter"
          },
          { "name": "catchall.data.nodeType",
            "label": "Node Type",
            "cell": "String",
            "editable": false
          },
          { "name": "nodes.configuration.roleType",
            "label": "Role",
            "cell": "String",
            "editable": false
          },
          { "name": "catchall.data.nodeVendor",
            "label": "Vendor",
            "cell": "String",
            "editable": false
          },
          { "name": "location",
            "label": "Location",
            "cell": "FilterString",
            "search" : "iregex",
            "editable": false,
            "headerCell": "filter"
          },
          { "name": "latest_data.subconcepts.health.derived_data.08_health",
            "label": "Health",
            "cell": "ColouredByLevel",
            "levels": [ "green", 100, "yellow", 99, "orange", 80, "red", 0 ],
            "sortable": false,
            "editable": false
          },
          { "name": "catchall.data.last_poll",
            "label": "Last Poll",
            "cell": "String",
            "formatter": "UnixTime",
            "editable": false
          },
          { "name": "catchall.data.remote_connection_url",
            "renderable": 0,
            "cell": "String",
            "editable": false
          },
          { "name": "catchall.data.remote_connection_name",
            "renderable": 0,
            "cell": "String",
            "editable": false
          },
          { "name": "catchall.data.node_context_url",
            "renderable": 0,
            "cell": "String",
            "editable": false
          },
          { "name": "catchall.data.node_context_name",
            "renderable": 0,
            "cell": "String",
            "editable": false
          }
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
      axios.get('/api/v1/nodes/291a3d0e-289b-4027-903a-5b5f6d6ed002')
      .then(response => {
        console.log('response: ', response);
        this.data = response.data;
        this.isLoading = false;
      })
      //console.log("response", this.testData);
    },
    methods: {
      GetPropertyValue(dataToRetrieve) {
        return dataToRetrieve
          .split('.') // split string based on `.`
          .reduce(function(o, k) {
            return o && o[k]; // get inner property if `o` is defined else get `o` and return
          }, this.data) // set initial value as object
      }
    }
}
</script>