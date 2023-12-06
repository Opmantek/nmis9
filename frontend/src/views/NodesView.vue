<template>
    <div>
    <h1>Nodes Page</h1>
    <div v-if="nodes.length">
        <ul>
            <li v-for="node in nodes"><RouterLink  :to="{ name: 'nodeDetails', params: { uuid: node }}">{{node}}</RouterLink></li>
        </ul>
    </div>
</div>
</template>

<script>
import axios from 'axios';

export default {
    data() {
        return {
            nodes: []
        }
    },
    created() {
        axios.get('api/v1/nodes')
        .then(response => {
            this.nodes = response.data;
        })
    }
}

</script>