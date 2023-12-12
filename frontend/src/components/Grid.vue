<template>
    <table class="table">
        <thead>
            <tr>
                <th v-for="cell in schema" :key="cell">{{ cell.label }}</th>
            </tr>
        </thead>
        <tbody>
            <tr v-for="d in data" :key="d">
                <th v-for="cell in headerCells" :key="cell">{{ data[cell]}}</th>
            </tr>
        </tbody>
    </table>
</template>

<script>

export default {
    props: {
        schema: {
            type: 'Object',
            required: true
        },
        data: {
            type: []
        }
    },
    computed: {
      headerCells() {
        return Object.keys(this.schema);
      },
    },
}


</script>