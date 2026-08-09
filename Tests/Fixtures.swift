import Foundation

/// Przykładowe dokumenty budowane zgodnie ze schematami opublikowanymi przez Ministerstwo Finansów
/// (`schemat_FA(3)_v1-0E.xsd`, `schemat_FA(2)_v1-0E.xsd`, PEF/UBL 2.1).
enum Fixtures {
    static let fa3NamespaceURI = "http://crd.gov.pl/wzor/2025/06/25/13775/"
    static let fa2NamespaceURI = "http://crd.gov.pl/wzor/2023/06/29/12648/"

    /// Faktura FA(3): dwie stawki VAT, trzy pozycje, MPP, przelew z terminem i rachunkiem.
    /// Trzecia pozycja celowo nie ma pól P_11Vat i P_11A — sprawdza wyliczenia zastępcze.
    static let fa3Standard = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Faktura xmlns="\(fa3NamespaceURI)"
             xmlns:etd="http://crd.gov.pl/xml/schematy/dziedzinowe/mf/2022/01/05/eD/DefinicjeTypy/">
      <Naglowek>
        <KodFormularza kodSystemowy="FA (3)" wersjaSchemy="1-0E">FA</KodFormularza>
        <WariantFormularza>3</WariantFormularza>
        <DataWytworzeniaFa>2026-07-15T10:12:00Z</DataWytworzeniaFa>
        <SystemInfo>Testy jednostkowe</SystemInfo>
      </Naglowek>
      <Podmiot1>
        <DaneIdentyfikacyjne>
          <NIP>5260250274</NIP>
          <Nazwa>Przykładowa Spółka z o.o.</Nazwa>
        </DaneIdentyfikacyjne>
        <Adres>
          <AdresPol>
            <KodKraju>PL</KodKraju>
            <Wojewodztwo>mazowieckie</Wojewodztwo>
            <Powiat>Warszawa</Powiat>
            <Gmina>Warszawa</Gmina>
            <Ulica>Świętokrzyska</Ulica>
            <NrDomu>12</NrDomu>
            <NrLokalu>34</NrLokalu>
            <Miejscowosc>Warszawa</Miejscowosc>
            <KodPocztowy>00-916</KodPocztowy>
          </AdresPol>
        </Adres>
        <DaneKontaktowe>
          <Email>biuro@przyklad.pl</Email>
          <Telefon>221234567</Telefon>
        </DaneKontaktowe>
      </Podmiot1>
      <Podmiot2>
        <DaneIdentyfikacyjne>
          <NIP>7010001453</NIP>
          <Nazwa>Nabywca Ćwiczebny S.A.</Nazwa>
        </DaneIdentyfikacyjne>
        <Adres>
          <AdresPol>
            <KodKraju>PL</KodKraju>
            <Ulica>Żurawia</Ulica>
            <NrDomu>7</NrDomu>
            <Miejscowosc>Kraków</Miejscowosc>
            <KodPocztowy>31-042</KodPocztowy>
          </AdresPol>
        </Adres>
      </Podmiot2>
      <Fa>
        <KodWaluty>PLN</KodWaluty>
        <P_1>2026-07-15</P_1>
        <P_1M>Warszawa</P_1M>
        <P_2>FV/123/2026</P_2>
        <P_6>2026-07-14</P_6>
        <P_13_1>1000.00</P_13_1>
        <P_14_1>230.00</P_14_1>
        <P_13_2>500.00</P_13_2>
        <P_14_2>40.00</P_14_2>
        <P_15>1770.00</P_15>
        <Adnotacje>
          <P_16>1</P_16>
          <P_17>1</P_17>
          <P_18>1</P_18>
          <P_18A>2</P_18A>
          <Zwolnienie>
            <P_19N>1</P_19N>
          </Zwolnienie>
          <NoweSrodkiTransportu>
            <P_22N>1</P_22N>
          </NoweSrodkiTransportu>
          <PMarzy>
            <P_PMarzyN>1</P_PMarzyN>
          </PMarzy>
        </Adnotacje>
        <RodzajFaktury>VAT</RodzajFaktury>
        <FaWiersz>
          <NrWierszaFa>1</NrWierszaFa>
          <P_7>Usługa doradcza — analiza wdrożenia</P_7>
          <P_8A>godz.</P_8A>
          <P_8B>10</P_8B>
          <P_9A>60.00</P_9A>
          <P_11>600.00</P_11>
          <P_11Vat>138.00</P_11Vat>
          <P_12>23</P_12>
          <GTU>GTU_12</GTU>
        </FaWiersz>
        <FaWiersz>
          <NrWierszaFa>2</NrWierszaFa>
          <P_7>Licencja roczna</P_7>
          <P_8A>szt.</P_8A>
          <P_8B>1</P_8B>
          <P_9A>400.00</P_9A>
          <P_11>400.00</P_11>
          <P_11Vat>92.00</P_11Vat>
          <P_12>23</P_12>
        </FaWiersz>
        <FaWiersz>
          <NrWierszaFa>3</NrWierszaFa>
          <P_7>Materiały szkoleniowe (książki)</P_7>
          <P_8A>szt.</P_8A>
          <P_8B>5</P_8B>
          <P_9A>100.00</P_9A>
          <P_11>500.00</P_11>
          <P_12>8</P_12>
        </FaWiersz>
        <Platnosc>
          <Zaplacono>1</Zaplacono>
          <DataZaplaty>2026-07-20</DataZaplaty>
          <FormaPlatnosci>6</FormaPlatnosci>
          <TerminPlatnosci>
            <Termin>2026-07-29</Termin>
          </TerminPlatnosci>
          <RachunekBankowy>
            <NrRB>61109010140000071219812874</NrRB>
            <NazwaBanku>Bank Przykładowy S.A.</NazwaBanku>
          </RachunekBankowy>
        </Platnosc>
      </Fa>
    </Faktura>
    """

    /// Faktura korygująca FA(3) z kwotami ujemnymi — sprawdza obsługę korekt „in minus".
    static let fa3Correction = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Faktura xmlns="\(fa3NamespaceURI)">
      <Naglowek>
        <KodFormularza kodSystemowy="FA (3)" wersjaSchemy="1-0E">FA</KodFormularza>
        <WariantFormularza>3</WariantFormularza>
      </Naglowek>
      <Podmiot1>
        <DaneIdentyfikacyjne>
          <NIP>5260250274</NIP>
          <Nazwa>Przykładowa Spółka z o.o.</Nazwa>
        </DaneIdentyfikacyjne>
      </Podmiot1>
      <Podmiot2>
        <DaneIdentyfikacyjne>
          <NIP>7010001453</NIP>
          <Nazwa>Nabywca Ćwiczebny S.A.</Nazwa>
        </DaneIdentyfikacyjne>
      </Podmiot2>
      <Fa>
        <KodWaluty>PLN</KodWaluty>
        <P_1>2026-07-28</P_1>
        <P_2>KOR/7/2026</P_2>
        <P_13_1>-200.00</P_13_1>
        <P_14_1>-46.00</P_14_1>
        <P_15>-246.00</P_15>
        <RodzajFaktury>KOR</RodzajFaktury>
        <PrzyczynaKorekty>Zwrot części towaru</PrzyczynaKorekty>
        <TypKorekty>1</TypKorekty>
        <DaneFaKorygowanej>
          <DataWystFaKorygowanej>2026-07-15</DataWystFaKorygowanej>
          <NrFaKorygowanej>FV/123/2026</NrFaKorygowanej>
          <NrKSeF>5260250274-20260715-01ABCDEF-01</NrKSeF>
        </DaneFaKorygowanej>
        <FaWiersz>
          <NrWierszaFa>1</NrWierszaFa>
          <P_7>Zwrot: Licencja roczna</P_7>
          <P_8A>szt.</P_8A>
          <P_8B>-1</P_8B>
          <P_9A>200.00</P_9A>
          <P_11>-200.00</P_11>
          <P_11Vat>-46.00</P_11Vat>
          <P_12>23</P_12>
        </FaWiersz>
      </Fa>
    </Faktura>
    """

    /// Faktura FA(3) w konwencji brutto (art. 106e ust. 7 i 8 ustawy): pozycje niosą wyłącznie
    /// wartość brutto `P_11A`, bez `P_9A`, `P_11` i `P_11Vat`.
    ///
    /// Kwoty odwzorowują rzeczywisty dokument ze sprzedaży detalicznej — podsumowanie stawek
    /// wypełnione przez wystawcę pozwala sprawdzić, że wartości wyliczone „w stu" zgadzają się
    /// co do grosza z tym, co zadeklarował.
    static let fa3GrossOnly = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Faktura xmlns="\(fa3NamespaceURI)">
      <Naglowek>
        <KodFormularza kodSystemowy="FA (3)" wersjaSchemy="1-0E">FA</KodFormularza>
      </Naglowek>
      <Podmiot1>
        <DaneIdentyfikacyjne>
          <NIP>5260250274</NIP>
          <Nazwa>Sprzedawca Detaliczny sp. z o.o.</Nazwa>
        </DaneIdentyfikacyjne>
      </Podmiot1>
      <Podmiot2>
        <DaneIdentyfikacyjne>
          <NIP>7010001453</NIP>
          <Nazwa>Gabinet Przykładowy</Nazwa>
        </DaneIdentyfikacyjne>
      </Podmiot2>
      <Fa>
        <KodWaluty>PLN</KodWaluty>
        <P_1>2026-07-13</P_1>
        <P_2>FV/312/07/2026/MED</P_2>
        <P_6>2026-07-13</P_6>
        <P_13_1>288.86</P_13_1>
        <P_14_1>66.44</P_14_1>
        <P_15>355.30</P_15>
        <RodzajFaktury>VAT</RodzajFaktury>
        <FaWiersz>
          <NrWierszaFa>1</NrWierszaFa>
          <P_7>Bluza medyczna, Wine, L</P_7>
          <P_8A>szt</P_8A>
          <P_8B>1</P_8B>
          <P_11A>160.65</P_11A>
          <P_12>23</P_12>
        </FaWiersz>
        <FaWiersz>
          <NrWierszaFa>2</NrWierszaFa>
          <P_7>Spodnie medyczne, Wine, M/R</P_7>
          <P_8A>szt</P_8A>
          <P_8B>1</P_8B>
          <P_11A>194.65</P_11A>
          <P_12>23</P_12>
        </FaWiersz>
        <Platnosc>
          <FormaPlatnosci>6</FormaPlatnosci>
        </Platnosc>
      </Fa>
    </Faktura>
    """

    /// Faktura FA(3) w euro z kursem przeliczeniowym i kwotą VAT wykazaną w złotych.
    static let fa3ForeignCurrency = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Faktura xmlns="\(fa3NamespaceURI)">
      <Naglowek>
        <KodFormularza kodSystemowy="FA (3)" wersjaSchemy="1-0E">FA</KodFormularza>
      </Naglowek>
      <Podmiot1>
        <DaneIdentyfikacyjne>
          <NIP>5260250274</NIP>
          <Nazwa>Przykładowa Spółka z o.o.</Nazwa>
        </DaneIdentyfikacyjne>
      </Podmiot1>
      <Podmiot2>
        <DaneIdentyfikacyjne>
          <NIP>7010001453</NIP>
          <Nazwa>Kontrahent Zagraniczny GmbH</Nazwa>
        </DaneIdentyfikacyjne>
      </Podmiot2>
      <Fa>
        <KodWaluty>EUR</KodWaluty>
        <P_1>2026-07-20</P_1>
        <P_2>FV/EUR/9/2026</P_2>
        <P_13_1>1000.00</P_13_1>
        <P_14_1>230.00</P_14_1>
        <P_14_1W>989.00</P_14_1W>
        <P_15>1230.00</P_15>
        <KursWalutyZ>4.3000</KursWalutyZ>
        <RodzajFaktury>VAT</RodzajFaktury>
        <FaWiersz>
          <NrWierszaFa>1</NrWierszaFa>
          <P_7>Usługa wdrożeniowa</P_7>
          <P_8A>szt.</P_8A>
          <P_8B>1</P_8B>
          <P_9A>1000.00</P_9A>
          <P_11>1000.00</P_11>
          <P_11Vat>230.00</P_11Vat>
          <P_12>23</P_12>
        </FaWiersz>
      </Fa>
    </Faktura>
    """

    /// Faktura FA(2) — starszy wzór, faktury archiwalne.
    static let fa2Standard = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Faktura xmlns="\(fa2NamespaceURI)">
      <Naglowek>
        <KodFormularza kodSystemowy="FA (2)" wersjaSchemy="1-0E">FA</KodFormularza>
        <WariantFormularza>2</WariantFormularza>
      </Naglowek>
      <Podmiot1>
        <DaneIdentyfikacyjne>
          <NIP>5260250274</NIP>
          <Nazwa>Przykładowa Spółka z o.o.</Nazwa>
        </DaneIdentyfikacyjne>
        <Adres>
          <AdresPol>
            <KodKraju>PL</KodKraju>
            <Miejscowosc>Warszawa</Miejscowosc>
            <KodPocztowy>00-916</KodPocztowy>
          </AdresPol>
        </Adres>
      </Podmiot1>
      <Podmiot2>
        <DaneIdentyfikacyjne>
          <NIP>7010001453</NIP>
          <Nazwa>Archiwalny Nabywca sp.j.</Nazwa>
        </DaneIdentyfikacyjne>
      </Podmiot2>
      <Fa>
        <KodWaluty>PLN</KodWaluty>
        <P_1>2024-03-11</P_1>
        <P_2>FA/2024/03/11</P_2>
        <P_13_1>2000.00</P_13_1>
        <P_14_1>460.00</P_14_1>
        <P_15>2460.00</P_15>
        <RodzajFaktury>VAT</RodzajFaktury>
        <FaWiersz>
          <NrWierszaFa>1</NrWierszaFa>
          <P_7>Usługa archiwalna</P_7>
          <P_8A>szt.</P_8A>
          <P_8B>2</P_8B>
          <P_9A>1000.00</P_9A>
          <P_11>2000.00</P_11>
          <P_11Vat>460.00</P_11Vat>
          <P_12>23</P_12>
        </FaWiersz>
      </Fa>
    </Faktura>
    """

    /// Faktura PEF w formacie UBL 2.1.
    static let pefUBL = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
             xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
             xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
      <cbc:ID>PEF/2026/07/55</cbc:ID>
      <cbc:IssueDate>2026-07-22</cbc:IssueDate>
      <cbc:DueDate>2026-08-05</cbc:DueDate>
      <cbc:DocumentCurrencyCode>PLN</cbc:DocumentCurrencyCode>
      <cac:AccountingSupplierParty>
        <cac:Party>
          <cac:PartyName><cbc:Name>Dostawca Publiczny sp. z o.o.</cbc:Name></cac:PartyName>
          <cac:PostalAddress>
            <cbc:StreetName>Marszałkowska</cbc:StreetName>
            <cbc:BuildingNumber>1</cbc:BuildingNumber>
            <cbc:CityName>Warszawa</cbc:CityName>
            <cbc:PostalZone>00-001</cbc:PostalZone>
            <cac:Country><cbc:IdentificationCode>PL</cbc:IdentificationCode></cac:Country>
          </cac:PostalAddress>
          <cac:PartyTaxScheme><cbc:CompanyID>PL5260250274</cbc:CompanyID></cac:PartyTaxScheme>
          <cac:PartyLegalEntity><cbc:RegistrationName>Dostawca Publiczny sp. z o.o.</cbc:RegistrationName></cac:PartyLegalEntity>
        </cac:Party>
      </cac:AccountingSupplierParty>
      <cac:AccountingCustomerParty>
        <cac:Party>
          <cac:PartyLegalEntity><cbc:RegistrationName>Urząd Miasta</cbc:RegistrationName></cac:PartyLegalEntity>
          <cac:PartyTaxScheme><cbc:CompanyID>PL7010001453</cbc:CompanyID></cac:PartyTaxScheme>
        </cac:Party>
      </cac:AccountingCustomerParty>
      <cac:TaxTotal>
        <cbc:TaxAmount currencyID="PLN">230.00</cbc:TaxAmount>
        <cac:TaxSubtotal>
          <cbc:TaxableAmount currencyID="PLN">1000.00</cbc:TaxableAmount>
          <cbc:TaxAmount currencyID="PLN">230.00</cbc:TaxAmount>
          <cac:TaxCategory><cbc:Percent>23</cbc:Percent></cac:TaxCategory>
        </cac:TaxSubtotal>
      </cac:TaxTotal>
      <cac:LegalMonetaryTotal>
        <cbc:TaxExclusiveAmount currencyID="PLN">1000.00</cbc:TaxExclusiveAmount>
        <cbc:TaxInclusiveAmount currencyID="PLN">1230.00</cbc:TaxInclusiveAmount>
        <cbc:PayableAmount currencyID="PLN">1230.00</cbc:PayableAmount>
      </cac:LegalMonetaryTotal>
      <cac:InvoiceLine>
        <cbc:ID>1</cbc:ID>
        <cbc:InvoicedQuantity unitCode="H87">4</cbc:InvoicedQuantity>
        <cbc:LineExtensionAmount currencyID="PLN">1000.00</cbc:LineExtensionAmount>
        <cac:Item>
          <cbc:Name>Dostawa materiałów biurowych</cbc:Name>
          <cac:ClassifiedTaxCategory><cbc:Percent>23</cbc:Percent></cac:ClassifiedTaxCategory>
        </cac:Item>
        <cac:Price><cbc:PriceAmount currencyID="PLN">250.00</cbc:PriceAmount></cac:Price>
      </cac:InvoiceLine>
    </Invoice>
    """

    /// Faktura z 60 pozycjami — sprawdza podział długiego dokumentu na strony A4.
    static func fa3WithManyLines(_ count: Int) -> String {
        var lines = ""
        for index in 1 ... count {
            lines += """
              <FaWiersz>
                <NrWierszaFa>\(index)</NrWierszaFa>
                <P_7>Pozycja testowa numer \(index) — opis towaru z polskimi znakami ąćęłńóśźż</P_7>
                <P_8A>szt.</P_8A>
                <P_8B>1</P_8B>
                <P_9A>100.00</P_9A>
                <P_11>100.00</P_11>
                <P_11Vat>23.00</P_11Vat>
                <P_12>23</P_12>
              </FaWiersz>

            """
        }
        let net = Decimal(count) * 100
        let vat = Decimal(count) * 23
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Faktura xmlns="\(fa3NamespaceURI)">
          <Naglowek><KodFormularza kodSystemowy="FA (3)" wersjaSchemy="1-0E">FA</KodFormularza></Naglowek>
          <Podmiot1>
            <DaneIdentyfikacyjne><NIP>5260250274</NIP><Nazwa>Przykładowa Spółka z o.o.</Nazwa></DaneIdentyfikacyjne>
          </Podmiot1>
          <Podmiot2>
            <DaneIdentyfikacyjne><NIP>7010001453</NIP><Nazwa>Nabywca Ćwiczebny S.A.</Nazwa></DaneIdentyfikacyjne>
          </Podmiot2>
          <Fa>
            <KodWaluty>PLN</KodWaluty>
            <P_1>2026-07-31</P_1>
            <P_2>FV/DLUGA/2026</P_2>
            <P_13_1>\(Fmt.plainNumber(net))</P_13_1>
            <P_14_1>\(Fmt.plainNumber(vat))</P_14_1>
            <P_15>\(Fmt.plainNumber(net + vat))</P_15>
            <RodzajFaktury>VAT</RodzajFaktury>
        \(lines)  </Fa>
        </Faktura>
        """
    }

    static func data(_ xml: String) -> Data {
        Data(xml.utf8)
    }

    /// Metadane odpowiadające fakturze `fa3Standard`.
    static func metadata(ksefNumber: String = "5260250274-20260715-01ABCDEF-01") -> InvoiceMetadata {
        InvoiceMetadata(
            ksefNumber: ksefNumber,
            invoiceNumber: "FV/123/2026",
            issueDate: "2026-07-15",
            invoicingDate: Date(timeIntervalSince1970: 1_784_000_000),
            acquisitionDate: Date(timeIntervalSince1970: 1_784_000_000),
            permanentStorageDate: Date(timeIntervalSince1970: 1_784_000_100),
            seller: InvoiceMetadataSeller(nip: "5260250274", name: "Przykładowa Spółka z o.o."),
            buyer: InvoiceMetadataBuyer(
                identifier: InvoiceMetadataBuyerIdentifier(type: "Nip", value: "7010001453"),
                name: "Nabywca Ćwiczebny S.A."
            ),
            netAmount: 1500,
            grossAmount: 1770,
            vatAmount: 270,
            currency: "PLN",
            invoicingMode: "Online",
            invoiceType: "Vat",
            formCode: FormCode(systemCode: "FA (3)", schemaVersion: "1-0E", value: "FA"),
            isSelfInvoicing: false,
            hasAttachment: false,
            invoiceHash: nil,
            hashOfCorrectedInvoice: nil
        )
    }
}
