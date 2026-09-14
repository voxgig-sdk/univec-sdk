<template>
  <div class="docgen-frame">
    <header v-pre><span class="deck-title">{{logoImage}}{{title}}</span>{{providerLink}}</header>
    <footer><span class="deck-notice" v-pre>{{shortNotice}}</span><span class="page-number" aria-label="Slide number">{{ $page }} / {{ $slidev.nav.total }}</span></footer>
  </div>
</template>
