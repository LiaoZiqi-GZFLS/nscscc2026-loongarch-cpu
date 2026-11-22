# TLB user-fetch probe: 3 markers to test first-fetch corruption.
        li      t7, 0x1c220500
        li      t3, 0x1c400000
        li      t0, 0x1580d80c          # lu12i.w t0, 0xc0d0c  (M1 hi)
        st.w    t0, t3, 0
        li      t0, 0x0380018c          # ori t0, t0, 0
        st.w    t0, t3, 4
        li      t0, 0x2980226c          # st.w t0, t7, 8  -> M1 @ 1c220508
        st.w    t0, t3, 8
        li      t0, 0x1580e2c          # lu12i.w t0, 0xc0e2c  (M2 hi)
        st.w    t0, t3, 12
        li      t0, 0x0380018c          # ori t0, t0, 0
        st.w    t0, t3, 16
        li      t0, 0x2980326c          # st.w t0, t7, 12 -> M2 @ 1c22050c
        st.w    t0, t3, 20
        li      t0, 0x1580f4c          # lu12i.w t0, 0xc0f4c  (M3 hi)
        st.w    t0, t3, 24
        li      t0, 0x0380018c          # ori t0, t0, 0
        st.w    t0, t3, 28
        li      t0, 0x2980426c          # st.w t0, t7, 16 -> M3 @ 1c220510
        st.w    t0, t3, 32
        li      t0, 0x50000000          # b .
        st.w    t0, t3, 36
        # DMW0: VSEG0->PSEG0 PLV0+PLV3 uncached
        li      t0, 0x00000009
        csrwr   t0, 0x180
        # TLB: VA 0x40000000 -> PA 0x1c400000, PS=12
        li      t0, 0
        csrwr   t0, 0x18
        li      t0, 0x40000000
        csrwr   t0, 0x11
        li      t0, 0x01c4000f
        csrwr   t0, 0x12
        li      t0, 0x01c4010f
        csrwr   t0, 0x13
        li      t0, 0x0c000000
        csrwr   t0, 0x10
        tlbwr
        li      t0, 0xa1a10000
        st.w    t0, t7, 0
        # DA -> PG
        li      t0, 0x10
        li      t1, 0x18
        csrxchg t0, t1, 0x0
        li      t0, 0xb2b20000
        st.w    t0, t7, 4
        # ertn to user
        li      t0, 0x40000000
        csrwr   t0, 0x6
        li      t1, 3
        csrwr   t1, 0x1
        ertn
