const ArtworkImage = {
  mounted() {
    this.image = this.el.querySelector("[data-artwork-image]")
    this.fallback = this.el.querySelector("[data-artwork-fallback]")

    this.showImage = () => {
      if (this.image) this.image.hidden = false
      if (this.fallback) this.fallback.hidden = true
      this.el.dataset.imageState = "loaded"
    }

    this.showFallback = () => {
      if (this.image) this.image.hidden = true
      if (this.fallback) this.fallback.hidden = false
      this.el.dataset.imageState = "error"
    }

    if (!this.image) {
      this.showFallback()
      this.el.dataset.imageState = "empty"
      return
    }

    this.image.addEventListener("load", this.showImage)
    this.image.addEventListener("error", this.showFallback)

    if (this.image.complete) {
      this.image.naturalWidth > 0 ? this.showImage() : this.showFallback()
    }
  },

  destroyed() {
    if (!this.image) return

    this.image.removeEventListener("load", this.showImage)
    this.image.removeEventListener("error", this.showFallback)
  },
}

export default ArtworkImage
