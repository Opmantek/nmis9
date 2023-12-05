<template>
    <h1>Nodes Page</h1>
    <div v-if="nodes.length">
        <ul>
            <li v-for="node in nodes">{{ node }}</li>
        </ul>
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
            console.log('nodes: ', response);
            this.nodes = response.data;
        })
    }
}

</script>