<template>
    <div class="card">
        <div class="card-header">
            <h5 class="card-title">Node Search</h5>
        </div>
        <div class="card-body">
            <VueMultiselect
                v-model="selected"
                @select="showNodeDetails"
                :options="nodes"
                :multiple="false"
                :searchable="true"
                @search-change="nodesQuery"
                placeholder="Type to search"
                >
            <template #noResult>
                No results found. Consider changing the search query
            </template>
</VueMultiselect>
        </div>
    </div>
</template>
<script>
import VueMultiselect from 'vue-multiselect'
import axios from 'axios';
export default {
  components: { VueMultiselect },
  data () {
    return {
      selected: null,
      options: ['list', 'of', 'options'],
      nodes: []
    }
  },
  methods: {
    nodesQuery(query) {
        console.log('search');
        axios.get('api/v1/nodes')
        .then(response => {
            this.nodes = response.data;
        })
    },
    showNodeDetails() {
        this.$router.push({name: 'nodeDetails', params: { uuid: this.selected}});
    }
  }
}
</script>

<style src="vue-multiselect/dist/vue-multiselect.css"></style>
<style>
    .multiselect__option--highlight, .multiselect__option--highlight::after {
        background: #16325c
    }
@media (prefers-color-scheme: dark) {
    .multiselect__spinner::before,
  .multiselect__spinner::after {
    border-color: #41b883 transparent transparent;
  }
    .multiselect__tags, .multiselect__tag{
        background-color: #05090B;
    }
    .multiselect, .multiselect__single {
        background-color: #05090B;
        color: #FFF;
    }
    .multiselect__content-wrapper {
        background-color: #05090B;
    }
    .multiselect__element {
        background-color: #05090B;
        color: #FFF;
    }
    .multiselect__input {
        background: #05090B;
        color: #FFF;
    }

}
   


</style>