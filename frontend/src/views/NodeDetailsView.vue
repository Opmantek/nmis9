<template>
    <div>
        <h3>This is {{ uuid }} node</h3>
    </div>
</template>

<script>

export default {
    computed: {
    uuid() {
      return this.$route.params.uuid
    },
  },
}
</script>